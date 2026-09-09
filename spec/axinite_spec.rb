require 'spec_helper'
require 'stringio'

RSpec.describe Axinite do
  it 'does not scan on load or resume without a session' do
    expect(Axinite.scan?).to be false
    Axinite.resume
    repeated_queries
    expect(Axinite.finish).to eq([])
  end

  it 'counts identical repetitions and returns structured reports' do
    Axinite.scan
    repeated_queries
    report = Axinite.finish.fetch(0)
    expect(report[:queries].size).to eq(2)
    expect(report[:queries].uniq.size).to eq(1)
    expect(report[:client_id]).to eq(1)
    expect(report[:stack]).not_to be_empty
    expect(Axinite.scan?).to be false
  end

  it 'groups changed literals on the same full stack' do
    Axinite.scan
    2.times { |i| query("SELECT Id FROM Contact WHERE Age__c = #{i}") }
    expect(Axinite.finish.size).to eq(1)
  end

  it 'separates clients, fingerprints and complete caller paths' do
    Axinite.scan
    2.times { |i| query(client_id: i) }
    query('SELECT Id FROM Account')
    query('SELECT Name FROM Account')
    query
    query
    expect(Axinite.finish).to eq([])
  end

  it 'does not merge distinct outer frames with the same inner call site' do
    Axinite.scan
    repeated_queries(1)
    repeated_queries(1)
    expect(Axinite.finish).to eq([])
  end

  it 'retains identical query arrays from distinct full stacks' do
    Axinite.scan
    repeated_queries
    repeated_queries
    reports = Axinite.finish
    expect(reports.size).to eq(2)
    expect(reports.map { |report| report[:queries] }.uniq.size).to eq(1)
    expect(reports.map { |report| report[:stack] }.uniq.size).to eq(2)
  end

  it 'retains identical query arrays from distinct clients' do
    Axinite.scan
    [1, 1, 2, 2].each { |client| query(client_id: client) }
    reports = Axinite.finish
    expect(reports.map { |report| report[:client_id] }).to eq([1, 2])
    expect(reports.map { |report| report[:queries] }.uniq.size).to eq(1)
    expect(reports.map { |report| report[:stack] }.uniq.size).to eq(1)
  end

  it 'rejects ineligible queries before capturing stacks or fingerprinting' do
    Axinite.ignore_queries = ['ignored', /excluded/]
    expect(Axinite).not_to receive(:caller_locations)
    expect(Axinite).not_to receive(:fingerprint)
    Axinite.scan do
      query(exception: ['Error', 'fake'])
      query(exception_object: RuntimeError.new('fake'))
      query(nil)
      query('ignored')
      query('excluded query')
    end
  end

  it 'attributes monotonic milliseconds only to each complete qualifying group' do
    # Supported notification subscription obtains these seconds from CLOCK_MONOTONIC.
    allow(Process).to receive(:clock_gettime).and_call_original
    expect(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC)
      .and_return(10.0, 10.001, 20.0, 20.002, 30.0, 30.004, 40.0, 40.008,
                  50.0, 50.016, 60.0, 60.032, 70.0, 71.0, 80.0, 81.0)
    Axinite.ignore_queries = ['ignored']
    Axinite.scan
    [
      ['SELECT Id FROM Contact', 1, {}], ['SELECT Id FROM Contact', 1, {}],
      ['SELECT Name FROM Contact', 1, {}], ['SELECT Name FROM Contact', 1, {}],
      ['SELECT Id FROM Contact', 2, {}], ['SELECT Id FROM Contact', 2, {}],
      ['SELECT Id FROM Contact', 1, { exception: ['Error', 'fake'] }],
      ['ignored', 1, {}]
    ].each { |soql, client, extra| query(soql, client_id: client, **extra) }
    reports = Axinite.finish
    expect(reports.size).to eq(3)
    expect(reports.map { |report| report[:stack] }.uniq.size).to eq(1)
    expect(reports.map { |report| report[:queries].size }).to eq([2, 2, 2])
    reports.zip([3, 12, 48]).each do |report, duration|
      expect(report[:duration_ms]).to be_within(0.000001).of(duration)
    end
  end

  [nil, :failed, :ignored].each do |overlap|
    it "keeps overlapping fiber query timing isolated with #{overlap || 'successful'} events" do
      allow(Process).to receive(:clock_gettime).and_call_original
      expect(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC)
        .and_return(10.0, 20.0, 21.0, 22.0, 30.0, 40.0, 41.0, 42.0)
      Axinite.ignore_queries = ['ignored']
      fibers = [1, 2].map do |client|
        Fiber.new do
          Axinite.scan
          2.times do
            payload = { soql: 'SELECT Id FROM Contact', client_id: client }
            payload[:exception] = ['Error', 'fake'] if client == 2 && overlap == :failed
            payload[:soql] = 'ignored' if client == 2 && overlap == :ignored
            ActiveSupport::Notifications.instrument('query.active_force', payload) { Fiber.yield }
            Fiber.yield
          end
          reports = Axinite.finish
          expect(Axinite.scan?).to be false
          reports
        end
      end
      4.times { fibers.each(&:resume) }
      reports = fibers.map(&:resume)
      expect(reports[0].size).to eq(1)
      expect(reports[0][0][:queries].size).to eq(2)
      expect(reports[0][0][:client_id]).to eq(1)
      expect(reports[0][0][:duration_ms]).to eq(22_000)
      if overlap
        expect(reports[1]).to eq([])
      else
        expect(reports[1][0][:queries].size).to eq(2)
        expect(reports[1][0][:client_id]).to eq(2)
        expect(reports[1][0][:duration_ms]).to eq(4_000)
      end
      expect(Axinite.scan?).to be false
    end
  end

  it 'balances nested query timing and inactive markers' do
    allow(Process).to receive(:clock_gettime).and_return(10.0, 11.0, 12.0, 14.0)
    Axinite.scan
    ActiveSupport::Notifications.instrument('query.active_force', soql: 'outer') do
      ActiveSupport::Notifications.instrument('query.active_force', soql: 'inner') {}
      Axinite.pause { query }
    end
    groups = Thread.current[:axinite_session].groups.values
    expect(groups.map { |group| group[:duration_ms] }).to eq([1000, 4000])
    expect(Thread.current[:axinite_query_timings]).to be_nil
  end

  it 'does not attribute an event to a replacement session' do
    Axinite.scan
    ActiveSupport::Notifications.instrument('query.active_force', soql: 'outer') do
      Axinite.finish
      Axinite.scan
    end
    expect(Thread.current[:axinite_session].groups).to be_empty
    expect(Thread.current[:axinite_query_timings]).to be_nil
  end

  it 'clears timing state on original query and collector errors' do
    original = RuntimeError.new('original')
    expect do
      Axinite.scan do
        ActiveSupport::Notifications.instrument('query.active_force', soql: 'failed') { raise original }
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    expect(Thread.current[:axinite_query_timings]).to be_nil
    expect(Axinite.scan?).to be false
    allow(Axinite).to receive(:fingerprint).and_raise(original)
    expect { Axinite.scan { query } }.to raise_error { |error| expect(error).to equal(original) }
    expect(Thread.current[:axinite_query_timings]).to be_nil
    expect(Axinite.scan?).to be false
  end

  [nil, :paused, :disabled].each do |state|
    it "cleans sibling start failures and #{state || 'active'} ownership markers" do
      original = RuntimeError.new('subscriber start failed')
      sibling = Object.new
      sibling.define_singleton_method(:start) { |*| raise original }
      sibling.define_singleton_method(:finish) { |*| }
      token = nil
      expect do
        Axinite.scan do
          repeated_queries
          ActiveSupport::Notifications.instrument('query.active_force', soql: 'outer') do
            Axinite.pause if state == :paused
            Axinite.enabled = false if state == :disabled
            token = ActiveSupport::Notifications.subscribe('query.active_force', sibling)
            query
          end
        end
      end.to raise_error { |error| expect(error).to equal(original) }
      expect(Axinite.scan?).to be false
      expect(Thread.current[:axinite_query_timings]).to be_nil
      ActiveSupport::Notifications.unsubscribe(token)
      token = nil
      expect(Process).not_to receive(:clock_gettime)
      query
      expect(Thread.current[:axinite_query_timings]).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(token) if token
    end
  end

  it 'matches a rescued nested start failure to the outer fresh payload' do
    original = RuntimeError.new('nested start failed')
    sibling = Object.new
    sibling.define_singleton_method(:start) { |*, payload| raise original if payload[:soql] == 'inner' }
    sibling.define_singleton_method(:finish) { |*| }
    token = ActiveSupport::Notifications.subscribe('query.active_force', sibling)
    allow(Process).to receive(:clock_gettime).and_return(10.0, 11.0, 14.0)
    Axinite.scan
    # Like ActiveForce#execute_query, every logical event has a fresh payload.
    ActiveSupport::Notifications.instrument('query.active_force', soql: 'outer') do
      expect { query('inner') }.to raise_error { |error| expect(error).to equal(original) }
    end
    groups = Thread.current[:axinite_session].groups.values
    expect(groups.map { |group| group[:duration_ms] }).to eq([4000])
    expect(Thread.current[:axinite_query_timings]).to be_nil
  ensure
    ActiveSupport::Notifications.unsubscribe(token) if token
  end

  it 'cleans a top-level sibling start failure without finishing notifications' do
    original = RuntimeError.new('start failed')
    sibling = Object.new
    sibling.define_singleton_method(:start) { |*| raise original }
    sibling.define_singleton_method(:finish) { |*| }
    token = nil
    expect do
      Axinite.scan do
        repeated_queries
        token = ActiveSupport::Notifications.subscribe('query.active_force', sibling)
        query
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    expect(Thread.current[:axinite_query_timings]).to be_nil
    expect(Axinite.scan?).to be false
  ensure
    ActiveSupport::Notifications.unsubscribe(token) if token
  end

  it 'cleans manual paused markers without consuming a replacement event' do
    allow(Process).to receive(:clock_gettime).and_return(10.0, 20.0, 24.0)
    Axinite.scan
    ActiveSupport::Notifications.instrument('query.active_force', soql: 'old') do
      Axinite.pause do
        ActiveSupport::Notifications.instrument('query.active_force', soql: 'paused') do
          Axinite.finish
          expect(Thread.current[:axinite_query_timings]).to be_nil
          Axinite.scan
          query('replacement')
        end
      end
    end
    groups = Thread.current[:axinite_session].groups.values
    expect(groups.map { |group| group[:queries] }).to eq([['replacement']])
    expect(groups.map { |group| group[:duration_ms] }).to eq([4000])
    expect(Thread.current[:axinite_query_timings]).to be_nil
  end

  it 'leaves a replacement session owned by its caller after an original block error' do
    original = RuntimeError.new('original block')
    expect do
      Axinite.scan do
        Axinite.finish
        Axinite.scan
        repeated_queries
        raise original
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    expect(Axinite.scan?).to be true
    expect(Axinite.finish.size).to eq(1)
    expect(Thread.current[:axinite_query_timings]).to be_nil
  end

  it 'preserves replacement timing frames when an old owned block exits' do
    original = RuntimeError.new('replacement start failed')
    sibling = Object.new
    sibling.define_singleton_method(:start) { |*| raise original }
    sibling.define_singleton_method(:finish) { |*| }
    token = ActiveSupport::Notifications.subscribe('query.active_force', sibling)
    expect do
      Axinite.scan do
        Axinite.finish
        Axinite.scan
        query
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    expect(Axinite.scan?).to be true
    frames = Thread.current[:axinite_query_timings]
    expect(frames.size).to eq(1)
    expect(frames.first[0]).to equal(Thread.current[:axinite_session])
    Axinite.finish
    expect(Thread.current[:axinite_query_timings]).to be_nil
  ensure
    ActiveSupport::Notifications.unsubscribe(token) if token
  end

  it 'does not clear another fiber timing frame after a sibling start failure' do
    allow(Process).to receive(:clock_gettime).and_return(10.0, 11.0, 14.0)
    fiber = Fiber.new do
      Axinite.scan
      ActiveSupport::Notifications.instrument('query.active_force', soql: 'other fiber') { Fiber.yield }
      duration = Thread.current[:axinite_session].groups.values.first[:duration_ms]
      Axinite.finish
      expect(Thread.current[:axinite_query_timings]).to be_nil
      duration
    end
    fiber.resume
    original = RuntimeError.new('start failed')
    sibling = Object.new
    sibling.define_singleton_method(:start) { |*| raise original }
    sibling.define_singleton_method(:finish) { |*| }
    token = ActiveSupport::Notifications.subscribe('query.active_force', sibling)
    expect { Axinite.scan { query } }.to raise_error { |error| expect(error).to equal(original) }
    expect(Thread.current[:axinite_query_timings]).to be_nil
    ActiveSupport::Notifications.unsubscribe(token)
    token = nil
    expect(fiber.resume).to eq(4000)
  ensure
    ActiveSupport::Notifications.unsubscribe(token) if token
  end

  it 'does no timing work without a scan' do
    expect(Process).not_to receive(:clock_gettime)
    query
    expect(Thread.current[:axinite_query_timings]).to be_nil
  end

  it 'keeps composite queries and HTTP-cache-like logical hits' do
    Axinite.scan
    repeated_queries(2, transport: :composite_batch, cached: true)
    expect(Axinite.finish.size).to eq(1)
  end

  it 'ignores failed notification payloads' do
    Axinite.scan
    repeated_queries(2, exception: ['Error', 'fake'])
    repeated_queries(2, exception_object: RuntimeError.new('fake'))
    expect(Axinite.finish).to eq([])
  end

  it 'does not enumerate or change notification results' do
    result = Object.new
    expect(result).not_to receive(:each)
    Axinite.scan do
      expect(ActiveSupport::Notifications.instrument('query.active_force', soql: 'SELECT Id FROM Account', client_id: 1) { result }).to equal(result)
    end
  end

  it 'supports a validated threshold' do
    expect { Axinite.threshold = 1 }.to raise_error(ArgumentError)
    Axinite.threshold = 3
    Axinite.scan
    repeated_queries
    expect(Axinite.finish).to eq([])
  end

  it 'preserves scan and nested block returns with outer ownership' do
    expect(Axinite.scan { expect(Axinite.scan { :inner }).to eq(:inner); :outer }).to eq(:outer)
    Axinite.scan
    Axinite.scan { repeated_queries }
    expect(Axinite.scan?).to be true
    expect(Axinite.finish.size).to eq(1)
  end

  it 'preserves the original exception without reporting or leaking' do
    Axinite.raise = true
    original = RuntimeError.new('original')
    expect { Axinite.scan { repeated_queries; raise original } }.to raise_error { |error| expect(error).to equal(original) }
    expect(Axinite.scan?).to be false
    expect(Axinite.finish).to eq([])
  end

  it 'cleans state when reporting raises' do
    Axinite.raise = true
    expect { Axinite.scan { repeated_queries } }.to raise_error(Axinite::NPlusOneQueriesError, /SELECT Id FROM Contact/)
    expect(Axinite.scan?).to be false
    expect(Axinite.finish).to eq([])
  end

  it 'cleans state when a logger raises' do
    Axinite.custom_logger = double(warn: nil)
    allow(Axinite.custom_logger).to receive(:warn).and_raise('logger failed')
    expect { Axinite.scan { repeated_queries } }.to raise_error('logger failed')
    expect(Axinite.scan?).to be false
  end

  it 'supports local raising independently from global raising' do
    Axinite.start_raise
    expect(Axinite.raise?).to be true
    expect { Axinite.scan { repeated_queries } }.to raise_error(Axinite::NPlusOneQueriesError)
    Axinite.stop_raise
    expect(Axinite.raise?).to be false
  end

  it 'pauses with nested restoration, return values and exceptions' do
    Axinite.scan
    expect(Axinite.pause { Axinite.pause { repeated_queries }; :paused }).to eq(:paused)
    expect(Axinite.scan?).to be true
    expect { Axinite.pause { raise 'fake' } }.to raise_error('fake')
    expect(Axinite.scan?).to be true
    expect(Axinite.finish).to eq([])
  end

  it 'resumes imperative pauses without discarding accumulated queries' do
    Axinite.scan
    repeated_queries
    Axinite.pause
    repeated_queries
    Axinite.resume
    expect(Axinite.finish.fetch(0)[:queries].size).to eq(2)
  end

  it 'finishes paused sessions and never lets a nested scan steal them' do
    Axinite.scan
    repeated_queries
    Axinite.pause
    Axinite.scan { repeated_queries }
    expect(Axinite.scan?).to be false
    expect(Axinite.finish.size).to eq(1)
    Axinite.resume
    expect(Axinite.scan?).to be false
  end

  it 'can ignore pauses explicitly' do
    Axinite.ignore_pauses = true
    Axinite.scan
    Axinite.pause { repeated_queries }
    expect(Axinite.finish.size).to eq(1)
  end

  it 'can be disabled while preserving block returns' do
    Axinite.enabled = false
    expect(Axinite.scan { repeated_queries; :value }).to eq(:value)
    expect(Axinite.disabled?).to be true
    expect(Axinite.finish).to eq([])
  end

  it 'supports targeted query and stack ignores without default exemptions' do
    Axinite.ignore_queries = [/FROM Contact/]
    Axinite.scan { repeated_queries }
    Axinite.ignore_queries = []
    Axinite.allow_stack_paths = [/axinite_spec.rb/]
    Axinite.raise = true
    expect { Axinite.scan { repeated_queries } }.not_to raise_error
  end

  ['spec/axinite_spec.rb', /spec\/axinite_spec\.rb/].each do |path|
    it "ignores matching stack paths #{path.inspect}" do
      Axinite.allow_stack_paths = [path]
      Axinite.raise = true
      expect(Axinite.scan { repeated_queries; :value }).to eq(:value)
    end
  end

  ['not_a_matching_path', /not_a_matching_path/].each do |path|
    it "reports nonmatching stack paths #{path.inspect}" do
      Axinite.allow_stack_paths = [path]
      Axinite.raise = true
      expect { Axinite.scan { repeated_queries } }.to raise_error(Axinite::NPlusOneQueriesError)
    end
  end

  it 'keeps String query ignores exact rather than substring matches' do
    Axinite.ignore_queries = ['SELECT Id FROM Contact']
    Axinite.raise = true
    expect { Axinite.scan { repeated_queries } }.to raise_error(Axinite::NPlusOneQueriesError)
    Axinite.ignore_queries = ["SELECT Id FROM Contact WHERE AccountId = 'fake'"]
    expect { Axinite.scan { repeated_queries } }.not_to raise_error
  end

  it 'cleans stacks only for display and supports custom logging' do
    output = StringIO.new
    Axinite.custom_logger = Logger.new(output)
    Axinite.backtrace_cleaner = double(clean: ['display-only'])
    Axinite.scan
    repeated_queries
    report = Axinite.finish.fetch(0)
    expect(report[:stack]).not_to eq(['display-only'])
    expect(output.string).to include('display-only', 'SELECT Id FROM Contact', 'ms elapsed query time')
  end

  it 'isolates fibers on the same thread' do
    Axinite.scan
    fiber = Fiber.new do
      expect(Axinite.scan?).to be false
      Axinite.start_raise
      Axinite.scan
      repeated_queries
      Fiber.yield
      expect { Axinite.finish }.to raise_error(Axinite::NPlusOneQueriesError)
      Axinite.stop_raise
    end
    fiber.resume
    expect(Axinite.raise?).to be false
    expect(Axinite.finish).to eq([])
    fiber.resume
  end

  it 'isolates threads' do
    Axinite.scan
    Thread.new do
      expect(Axinite.scan?).to be false
      Axinite.scan
      repeated_queries
      expect(Axinite.finish.size).to eq(1)
    end.value
    expect(Axinite.finish).to eq([])
  end
end

RSpec.describe 'Axinite output choices' do
  it 'emits nothing without an explicit output choice' do
    expect { Axinite.scan { repeated_queries } }.not_to output.to_stderr
  end

  it 'logs raw SOQL to stderr on request' do
    Axinite.stderr_logger = true
    expect { Axinite.scan { repeated_queries } }.to output(/SELECT Id FROM Contact/).to_stderr
  end

  it 'logs to an explicit file path on request' do
    require 'tempfile'
    Tempfile.create('axinite') do |file|
      Axinite.axinite_logger = file.path
      Axinite.scan { repeated_queries }
      expect(File.read(file.path)).to include('SELECT Id FROM Contact')
    end
  end

  it 'logs through Rails only when explicitly configured' do
    logger = double('logger')
    stub_const('Rails', double('Rails', logger: logger))
    expect(logger).to receive(:warn).with(include('SELECT Id FROM Contact'))
    Axinite.rails_logger = true
    Axinite.scan { repeated_queries }
  end
end
