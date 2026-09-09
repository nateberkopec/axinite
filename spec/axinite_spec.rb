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
    expect(output.string).to include('display-only', 'SELECT Id FROM Contact')
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
