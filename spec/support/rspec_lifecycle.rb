# Isolated executable fixture: all records and transport events are synthetic.
require 'rspec/core'
require 'rspec/expectations'
require 'axinite/rspec'
require 'stringio'
require 'json'

mode, scenario, repeat, ordering = ARGV
output = StringIO.new
failure = RuntimeError.new('original failure')
Axinite.custom_logger = Logger.new(output)
Axinite.raise = true
queries = proc do
  if repeat == 'true'
    2.times do
      ActiveSupport::Notifications.instrument('query.active_force',
        soql: 'SELECT Id FROM Contact', client_id: 1) { :result }
    end
  end
end
around = proc do |example|
  queries.call if scenario == 'around_before'
  raise failure if scenario == 'around_before'
  example.run
  raise failure if scenario == 'around_after'
end
config = RSpec.configuration
config.around(:each, &around) if ordering == 'before'
Axinite::RSpec.install!(config, metadata: mode.start_with?('metadata') ? :axinite : nil) unless mode == 'baseline'
config.around(:each, &around) if ordering == 'after'
group = RSpec.describe('isolated lifecycle', axinite: mode != 'metadata_unselected',
  aggregate_failures: scenario.include?('aggregate'), skip: scenario == 'metadata_skip') do
  before do
    if scenario == 'before'
      queries.call
      raise failure
    end
  end
  after { raise failure if scenario == 'after' }
  it('runs') do
    queries.call
    pending('expected failure') if scenario.start_with?('pending')
    skip('runtime reason') if scenario == 'skip'
    raise failure if ['failure', 'pending'].include?(scenario)
    expect(1).to eq(2) if ['aggregate_failure', 'pending_aggregate_failure'].include?(scenario)
  end
end
status = RSpec::Core::Runner.run([], StringIO.new, StringIO.new)
example = group.examples.fetch(0)
result = example.execution_result
exception = example.exception || result.pending_exception
puts JSON.generate(exit: status, status: result.status, skipped: result.example_skipped?,
  exception: exception&.class&.name, message: exception&.message,
  original: exception.equal?(failure), logs: output.string,
  failed: config.reporter.failed_examples.size, pending: config.reporter.pending_examples.size,
  examples: config.reporter.examples.size, leaked: Axinite.scan? || !Axinite.finish.empty?)
