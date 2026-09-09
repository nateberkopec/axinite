require 'spec_helper'
require 'axinite/rspec'
require 'open3'
require 'json'

RSpec.describe Axinite::RSpec do
  it 'does nothing merely by being required' do
    expect(Axinite.scan?).to be false
  end

  %w[aggregate_failure aggregate_success skip metadata_skip pending pending_fixed
     pending_aggregate_failure pending_aggregate_success before after].each do |scenario|
    [false, true].each do |repeat|
      it "matches baseline lifecycle for #{scenario}, repetitions=#{repeat}" do
        baseline = lifecycle_result('baseline', scenario, repeat)
        %w[suite metadata].each do |mode|
          actual = lifecycle_result(mode, scenario, repeat)
          if scenario == 'aggregate_success' && repeat
            expect(actual.values_at('status', 'exception', 'failed')).to eq(
              ['failed', 'Axinite::NPlusOneQueriesError', 1])
            expect(actual['logs'].scan('N+1 queries detected').size).to eq(1)
          else
            expect(actual).to eq(baseline)
            expect(actual['logs']).to eq('')
          end
          expect(actual.values_at('examples', 'leaked')).to eq([1, false])
        end
      end
    end
  end

  it 'only installs into groups defined after installation' do
    script = <<~RUBY
      require 'rspec/core'
      require 'axinite/rspec'
      require 'stringio'
      observed = []
      RSpec.describe('existing group') do
        it('runs unscanned') { observed << Axinite.scan? }
      end
      Axinite::RSpec.install!(RSpec.configuration)
      RSpec.describe('subsequent group') do
        it('runs scanned') { observed << Axinite.scan? }
      end
      status = RSpec::Core::Runner.run([], StringIO.new, StringIO.new)
      abort 'unexpected lifecycle' unless status == 0 && observed == [false, true]
      abort 'session leaked' if Axinite.scan?
    RUBY
    stdout, stderr, status = Open3.capture3(Gem.ruby, '-Ilib', '-e', script)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it 'does not scan examples without the selected metadata' do
    expect(lifecycle_result('metadata_unselected', 'aggregate_success', true)).to eq(
      lifecycle_result('baseline', 'aggregate_success', true))
  end

  %w[before after].each do |ordering|
    %w[around_before around_after].each do |scenario|
      it "observes #{scenario} with user hook registered #{ordering} installation" do
        baseline = lifecycle_result('baseline', scenario, true, ordering)
        actual = lifecycle_result('suite', scenario, true, ordering)
        expect(actual).to eq(baseline)
        expect(actual.values_at('examples', 'leaked')).to eq([1, false])
      end
    end
  end

  def lifecycle_result(mode, scenario, repeat, ordering = 'none')
    stdout, stderr, status = Open3.capture3(Gem.ruby, '-Ilib',
      'spec/support/rspec_lifecycle.rb', mode, scenario, repeat.to_s, ordering)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
    JSON.parse(stdout)
  end

  [false, true].each do |repeat|
    it "preserves a real RSpec failure with repeated queries=#{repeat}" do
      run_lifecycle_example(repeat: repeat, fail_example: true)
    end
  end

  it 'detects repeated queries in a successful real RSpec example' do
    run_lifecycle_example(repeat: true, fail_example: false)
  end

  [false, true].each do |repeat|
    it "preserves an expected pending exception with repeated queries=#{repeat}" do
      run_lifecycle_example(repeat: repeat, fail_example: true, pending: true)
    end

    it "preserves pending-fixed failure semantics with repeated queries=#{repeat}" do
      run_lifecycle_example(repeat: repeat, fail_example: false, pending: true)
    end
  end

  def run_lifecycle_example(repeat:, fail_example:, pending: false)
    script = <<~RUBY
      require 'rspec/core'
      require 'axinite/rspec'
      require 'stringio'
      failure = RuntimeError.new('original failure')
      output = StringIO.new
      Axinite.custom_logger = Logger.new(output)
      Axinite.raise = true
      Axinite::RSpec.install!(RSpec.configuration)
      group = RSpec.describe('isolated lifecycle') do
        it('runs') do
          pending('expected failure') if #{pending}
          if #{repeat}
            2.times do
              ActiveSupport::Notifications.instrument('query.active_force',
                soql: 'SELECT Id FROM Contact', client_id: 1) { :result }
            end
          end
          raise failure if #{fail_example}
        end
      end
      status = RSpec::Core::Runner.run([], StringIO.new, StringIO.new)
      example = group.examples.fetch(0)
      abort 'wrong status' unless status == (#{pending && fail_example} ? 0 : 1)
      if #{pending}
        if #{fail_example}
          abort 'pending exception replaced or duplicated' unless example.execution_result.pending_exception.equal?(failure)
          abort 'wrong pending status' unless example.execution_result.status == :pending && example.exception.nil?
        else
          abort 'pending-fixed failure lost' unless example.exception.is_a?(RSpec::Core::Pending::PendingExampleFixedError)
          abort 'wrong fixed status' unless example.execution_result.status == :failed
        end
        abort 'secondary report' unless output.string.empty?
      elsif #{fail_example}
        abort 'original exception replaced or duplicated' unless example.exception.equal?(failure)
        abort 'secondary report' unless output.string.empty?
      else
        abort 'N+1 not detected' unless example.exception.is_a?(Axinite::NPlusOneQueriesError)
        abort 'missing report' unless output.string.include?('N+1 queries detected')
      end
      abort 'session leaked' if Axinite.scan? || !Axinite.finish.empty?
      abort 'failure counted twice' unless RSpec.configuration.reporter.failed_examples.size == (#{pending && fail_example} ? 0 : 1)
    RUBY
    stdout, stderr, status = Open3.capture3(Gem.ruby, '-Ilib', '-e', script)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it 'rejects unsupported RSpec core versions before installing' do
    stub_const('RSpec::Core::Version::STRING', '3.14.0')
    expect { described_class.install!(RSpec.configuration) }.to raise_error(ArgumentError, /rspec-core 3.13.x/)
  end

  it 'rejects a missing hook interface before installing' do
    expect { described_class.install!(Object.new) }.to raise_error(ArgumentError, /hooks.register/)
    expect { described_class.install!(double(hooks: Object.new)) }.to raise_error(ArgumentError, /hooks.register/)
  end

  [nil, :axinite].each do |metadata|
    it "installs an explicit #{metadata || 'suite'} hook" do
      hooks = double('hooks')
      config = double('config', hooks: hooks)
      example = double('example', exception: nil, execution_result: double(pending_exception: nil), metadata: {})
      filter = metadata ? [metadata] : []
      expect(hooks).to receive(:register).with(:append, :around, :each, *filter) do |&hook|
        expect(example).to receive(:run) { expect(Axinite.scan?).to be true }
        hook.call(example)
      end
      described_class.install!(config, metadata: metadata)
      expect(Axinite.scan?).to be false
    end
  end
end
