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
        Thread.current[:axinite_session] = nil if session.equal?(owned)
      end
    end

    def finish
      current = session
      return [] unless current

      # Release ownership before presentation/logging, including when they raise.
      Thread.current[:axinite_session] = nil
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

    def record(payload, locations)
      return unless scan?
      return if payload[:exception] || payload[:exception_object]
      soql = payload[:soql]
      return unless soql.is_a?(String)
      return if Array(ignore_queries).any? { |pattern| pattern === soql }

      stack = locations.map(&:to_s)
      return if stack.any? { |line| Array(allow_stack_paths).any? { |pattern| line.match?(pattern) } }

      full_stack = locations.map { |location| [location.path, location.lineno] }
      key = [full_stack, fingerprint(soql), payload[:client_id]]
      group = session.groups[key] ||= { queries: [], stack: stack, client_id: payload[:client_id], fingerprint: key[1] }
      group[:queries] << soql.dup
    end

    def notify(reports)
      text = reports.map do |report|
        stack = report[:stack].dup
        stack = backtrace_cleaner.clean(stack) if backtrace_cleaner
        "N+1 queries detected (#{report[:queries].size} logical executions):\n" \
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

  ActiveSupport::Notifications.subscribe('query.active_force') do |*args|
    record(args.last, caller_locations) if scan?
  end
end
