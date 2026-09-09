require 'logger'
require 'active_support'
require 'active_support/notifications'
require_relative 'axinite/version'
require_relative 'axinite/fingerprint'

# Adapted from Prosopite's lifecycle and grouping approach; see NOTICE.
module Axinite
  class NPlusOneQueriesError < StandardError; end
  Session = Struct.new(:groups, :paused)

  class << self
    attr_accessor :enabled, :raise, :stderr_logger, :rails_logger,
                  :custom_logger, :axinite_logger, :backtrace_cleaner,
                  :allow_stack_paths, :ignore_queries, :ignore_pauses
    attr_reader :min_n_queries

    def min_n_queries=(value)
      Kernel.raise ArgumentError, 'threshold must be an integer >= 2' unless value.is_a?(Integer) && value >= 2
      @min_n_queries = value
    end
    alias threshold min_n_queries
    alias threshold= min_n_queries=

    def enabled?
      !!enabled
    end

    def disabled?
      !enabled?
    end

    def scan?
      !!(enabled? && session && !session.paused)
    end

    def scan
      return block_given? ? yield : nil if session || disabled?

      owned = Session.new({}, false)
      Thread.current[:axinite_session] = owned
      return unless block_given?

      begin
        result = yield
        finish if session.equal?(owned)
        result
      ensure
        clear_query_timings(owned)
        Thread.current[:axinite_session] = nil if session.equal?(owned)
      end
    end

    def finish
      current = session
      return [] unless current

      # Release ownership before presentation/logging, including when they raise.
      Thread.current[:axinite_session] = nil
      clear_query_timings(current)
      reports = current.groups.values.select { |group| group[:queries].size >= min_n_queries }
      notify(reports) unless reports.empty?
      reports
    end

    def pause
      return block_given? ? yield : nil if ignore_pauses || !session

      current = session
      previous = current.paused
      current.paused = true
      return unless block_given?

      begin
        yield
      ensure
        current.paused = previous
      end
    end

    def resume
      session.paused = false if session
    end

    def start_raise
      Thread.current[:axinite_raise] = true
    end

    def stop_raise
      Thread.current[:axinite_raise] = false
    end

    def local_raise?
      Thread.current[:axinite_raise] == true
    end

    def raise?
      local_raise? || !!self.raise
    end

    def fingerprint(soql)
      Fingerprint.call(soql)
    end

    private

    def session
      Thread.current[:axinite_session]
    end

    def clear_query_timings(owner)
      timings = Thread.current[:axinite_query_timings]
      return unless timings

      timings.delete_if { |frame| frame[0].equal?(owner) }
      Thread.current[:axinite_query_timings] = nil if timings.empty?
    end

    def record(payload, started, finished)
      return unless scan?
      return if payload[:exception] || payload[:exception_object]
      soql = payload[:soql]
      return unless soql.is_a?(String)
      return if Array(ignore_queries).any? { |pattern| pattern === soql }

      locations = caller_locations
      stack = locations.map(&:to_s)
      return if stack.any? { |line| Array(allow_stack_paths).any? { |pattern| line.match?(pattern) } }

      full_stack = locations.map { |location| [location.path, location.lineno] }
      key = [full_stack, fingerprint(soql), payload[:client_id]]
      group = session.groups[key] ||= { queries: [], stack: stack, client_id: payload[:client_id], fingerprint: key[1], duration_ms: 0.0 }
      group[:queries] << soql.dup
      group[:duration_ms] += (finished - started) * 1000
    end

    def notify(reports)
      text = reports.map do |report|
        stack = report[:stack].dup
        stack = backtrace_cleaner.clean(stack) if backtrace_cleaner
        "N+1 queries detected (#{report[:queries].size} logical executions, #{report[:duration_ms].round(3)} ms elapsed query time):\n" \
          "#{report[:queries].map { |query| "  #{query}" }.join("\n")}\n" \
          "Call stack:\n#{stack.join("\n")}\n"
      end.join("\n")
      custom_logger.warn(text) if custom_logger
      Rails.logger.warn(text) if rails_logger
      $stderr.puts(text) if stderr_logger
      File.open(axinite_logger, 'a') { |file| file.puts(text) } if axinite_logger
      Kernel.raise NPlusOneQueriesError, text if raise?
    end
  end

  self.enabled = true
  self.min_n_queries = 2
  self.allow_stack_paths = []
  self.ignore_queries = []

  # Public start/finish subscribers avoid AS7's thread-shared monotonic stack.
  class QuerySubscriber
    def start(_name, _id, payload)
      timings = Thread.current[:axinite_query_timings]
      active = Axinite.scan?
      return unless active || timings

      timings ||= Thread.current[:axinite_query_timings] = []
      owner = Thread.current[:axinite_session]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC) if active
      timings << [owner, started, payload]
    end

    def finish(_name, _id, payload)
      timings = Thread.current[:axinite_query_timings]
      return unless timings

      # ActiveForce#execute_query supplies a fresh payload for each logical event.
      # Matching it also discards nested starts abandoned by a sibling's start error.
      # Reusing one payload for nested external events is not supported.
      index = timings.rindex { |frame| frame[2].equal?(payload) }
      return unless index

      frame = timings[index]
      timings.slice!(index..-1)
      Thread.current[:axinite_query_timings] = nil if timings.empty?
      return unless frame[1] && Axinite.scan? && Thread.current[:axinite_session].equal?(frame[0])

      Axinite.send(:record, payload, frame[1], Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end
  end
  private_constant :QuerySubscriber

  ActiveSupport::Notifications.subscribe('query.active_force', QuerySubscriber.new)
end
