require 'benchmark'
require 'axinite'

BATCHES = Integer(ENV.fetch('BATCHES', '100'))
QUERIES_PER_SCAN = 100
raise ArgumentError, 'BATCHES must be positive' unless BATCHES.positive?

# Distinct field names remain distinct fingerprints; literal values would collapse.
UNIQUE_QUERIES = Array.new(QUERIES_PER_SCAN) { |i| "SELECT Field#{i}__c FROM Account" }.freeze
REPEATED_QUERIES = Array.new(QUERIES_PER_SCAN, "SELECT Id FROM Account WHERE Name = 'synthetic'").freeze
MODEL = Class.new

def emit_queries(queries)
  queries.each do |soql|
    ActiveSupport::Notifications.instrument('query.active_force',
      soql: soql, model: MODEL, client_id: 1, transport: :query) { nil }
  end
end

cases = {
  'disabled' => proc do
    Axinite.enabled = false
    Axinite.scan { emit_queries(UNIQUE_QUERIES) }
  end,
  'enabled, no scan' => proc do
    Axinite.enabled = true
    emit_queries(UNIQUE_QUERIES)
  end,
  'scan, distinct queries' => proc do
    Axinite.enabled = true
    Axinite.scan { emit_queries(UNIQUE_QUERIES) }
  end,
  'scan, repeated queries' => proc do
    Axinite.enabled = true
    Axinite.scan { emit_queries(REPEATED_QUERIES) }
  end
}

puts "Ruby #{RUBY_VERSION}; ActiveSupport #{ActiveSupport::VERSION::STRING}; Axinite #{Axinite::VERSION}"
puts "#{BATCHES} batches of #{QUERIES_PER_SCAN} synthetic notifications; no Salesforce calls."
puts 'Scans include finish/report formatting, with all logging and raising disabled.'
printf "%-26s %12s %14s %16s\n", 'Case', 'seconds', 'us/query', 'objects/query'

cases.each do |name, run|
  5.times { run.call }
  GC.start
  before = GC.stat(:total_allocated_objects)
  elapsed = Benchmark.realtime { BATCHES.times { run.call } }
  allocated = GC.stat(:total_allocated_objects) - before
  count = BATCHES * QUERIES_PER_SCAN
  printf "%-26s %12.4f %14.2f %16.2f\n", name, elapsed, elapsed * 1_000_000 / count, allocated.to_f / count
end
