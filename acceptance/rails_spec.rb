require_relative 'support'

RSpec.describe 'Rails requests and ActiveJob with real ActiveForce and Restforce' do
  include SalesforceHTTP
  before { start_transport }
  after { stop_transport }

  it 'decodes Salesforce records as native Restforce SObjects over HTTP' do
    record = ActiveForce.sfdc_client.query('SELECT Id, Amount FROM Account').first
    expect(record).to be_a(Restforce::SObject)
    expect(record.Id).to eq('a1')
    expect(record.attributes.type).to eq('Account')
    expect(@http.size).to eq(1)
  end

  [
    'SELECT Id FROM Account',
    'SELECT Id, Amount FROM WrongTable',
    "SELECT count(Id) FROM Account WHERE (Id = 'missing')"
  ].each do |soql|
    it "rejects unsupported SOQL over HTTP: #{soql}" do
      expect { ActiveForce.sfdc_client.query(soql).to_a }.to raise_error(ArgumentError, "Unexpected fixture SOQL: #{soql}")
      expect(@http).to eq([soql])
    end
  end

  def expect_warning(count = 2)
    text = @output.string
    expect(text.scan('N+1 queries detected').size).to eq(1)
    expect(text).to include("#{count} logical executions", 'app/models/account.rb', @events.last.fetch(:soql))
    expect(Float(text.match(/, (-?[\d.]+) ms elapsed query time/)[1])).to be >= 0
    expect(@events.map { |event| event[:soql] }).to eq(@http)
    expect(@events.map { |event| event[:client_id] }.uniq).to eq([ActiveForce.sfdc_client.object_id])
    expect(Axinite.scan?).to be(false)
  end

  it 'rejects negative elapsed time in a real request diagnostic' do
    expect(request('lookup')).to eq([['a1'], ['a2']])
    expect(@http.size).to eq(2)
    expect(@events.size).to eq(2)
    expect_warning
    @output.string.sub!(/, [\d.]+ ms elapsed query time/, ', -1.0 ms elapsed query time')
    expect(@output.string).to include(', -1.0 ms elapsed query time')
    expect { expect_warning }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected: >= 0/)
  end

  {
    'contacts' => [['ca1'], ['ca2']],
    'primary_contact' => [['ca1'], ['ca2']],
    'belongs_to' => %w[a1 a2]
  }.each do |operation, expected|
    it "detects lazy #{operation} through the HTTP controller" do
      expect(request(operation)).to eq(expected)
      expect(@http.size).to eq(3)
      expect(@events.size).to eq(3)
      expect_warning
    end

    it "fixes #{operation} through real includes serialization" do
      expect(request("#{operation}_fixed")).to eq(expected)
      expect(@http.size).to eq(1)
      expect(@events.size).to eq(1)
      expect(@output.string).to be_empty
    end
  end

  { 'lookup' => [['a1'], ['a2']], 'count' => [1, 1], 'sum' => [3, 3] }.each do |operation, expected|
    it "detects explicit #{operation} loops" do
      expect(request(operation)).to eq(expected)
      expect(@http.size).to eq(2)
      expect(@events.size).to eq(2)
      expect_warning
    end
  end

  %w[count sum].each do |operation|
    it "replaces #{operation} loops with one bulk aggregate" do
      expect(request("#{operation}_fixed")).to eq(operation == 'count' ? 2 : 6)
      expect(@http.size).to eq(1)
      expect(@events.size).to eq(1)
      expect(@output.string).to be_empty
    end
  end

  it 'returns bulk results without repetition and isolates successive requests' do
    2.times { expect(request('bulk')).to eq(%w[a1 a2]) }
    expect(@http.size).to eq(2)
    expect(@events.size).to eq(2)
    expect(@output.string).to be_empty
    expect(Axinite.scan?).to be(false)
  end

  it 'does not scan model work outside request and job callbacks' do
    expect(Account.exercise('lookup')).to eq([['a1'], ['a2']])
    expect(@http.size).to eq(2)
    expect(@events.size).to eq(2)
    expect(@output.string).to be_empty
    expect(Axinite.scan?).to be(false)
    expect(request('bulk')).to eq(%w[a1 a2])
    expect(@output.string).to be_empty
  end

  it 'raises from the actual request callback and cleans up for the next request' do
    Axinite.raise = true
    expect { request('lookup') }.to raise_error(Axinite::NPlusOneQueriesError)
    expect(request('bulk')).to eq(%w[a1 a2])
    expect(Axinite.scan?).to be(false)
  end

  it 'preserves original controller errors without a secondary report' do
    Axinite.raise = true
    expect { request('error') }.to raise_error(ArgumentError, 'original application failure')
    expect(@http.size).to eq(2)
    expect(@output.string).to be_empty
    expect(Axinite.scan?).to be(false)
  end

  it 'scans actual jobs, raises, preserves errors and isolates later executions' do
    QueryJob.perform_now('lookup')
    expect(@http.size).to eq(2)
    expect_warning
    @output.truncate(0)
    @output.rewind
    2.times { expect(QueryJob.perform_now('bulk')).to eq(%w[a1 a2]) }
    expect(@output.string).to be_empty
    Axinite.raise = true
    expect { QueryJob.perform_now('lookup') }.to raise_error(Axinite::NPlusOneQueriesError)
    @output.truncate(0)
    @output.rewind
    expect { QueryJob.perform_now('error') }.to raise_error(ArgumentError, 'original application failure')
    expect(@output.string).to be_empty
    expect(Axinite.scan?).to be(false)
    QueryJob.perform_now('bulk')
  end

  it 'serializes a real composite batch and parses its response without false repetition' do
    ActiveForce.composite_batch_query_threshold = 1
    batches = []
    stub_request(:post, 'https://salesforce.invalid/services/data/v53.0/composite/batch').to_return do |http|
      body = JSON.parse(http.body)
      batches << body
      expect(body.fetch('haltOnError')).to be(false)
      expect(body.fetch('batchRequests').size).to eq(1)
      subrequest = body.fetch('batchRequests').fetch(0)
      expect(subrequest.fetch('method')).to eq('GET')
      uri = URI.parse(subrequest.fetch('url'))
      expect(uri.path).to eq('v53.0/query')
      soql = URI.decode_www_form(uri.query).to_h.fetch('q')
      expect(soql).to eq("SELECT Id, Amount FROM Account WHERE (Id IN ('a1','a2'))")
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(
        'hasErrors' => false, 'results' => [{ 'statusCode' => 200, 'result' => response_for(soql) }]
      ) }
    end
    expect(request('bulk')).to eq(%w[a1 a2])
    expect(batches.size).to eq(1)
    expect(@events.map { |event| event[:transport] }).to eq([:composite_batch])
    expect(@http).to be_empty
    expect(@output.string).to be_empty
  end

  it 'follows real nextRecordsUrl HTTP pagination within one logical execution' do
    first = collection([account_rows.first]).merge('done' => false, 'totalSize' => 2,
      'nextRecordsUrl' => '/services/data/v53.0/query/page-2')
    initial = stub_request(:get, 'https://salesforce.invalid/services/data/v53.0/query').with(
      query: { 'q' => "SELECT Id, Amount FROM Account WHERE (Id IN ('a1','a2'))" },
      headers: { 'Authorization' => 'OAuth synthetic-token' }).to_return(
      body: JSON.generate(first), headers: { 'Content-Type' => 'application/json' })
    page = stub_request(:get, 'https://salesforce.invalid/services/data/v53.0/query/page-2').with(
      headers: { 'Authorization' => 'OAuth synthetic-token' }).to_return(
      body: JSON.generate(collection([account_rows.last])), headers: { 'Content-Type' => 'application/json' })
    expect(request('bulk')).to eq(%w[a1 a2])
    expect(initial).to have_been_requested.once
    expect(page).to have_been_requested.once
    expect(@events.size).to eq(1)
    expect(@output.string).to be_empty
  end

  it 'demonstrates detector sensitivity without changing query execution' do
    Axinite.enabled = false
    expect(request('lookup')).to eq([['a1'], ['a2']])
    expect(@http.size).to eq(2)
    expect(@events.size).to eq(2)
    expect(@output.string).to be_empty
    Axinite.enabled = true
    request('lookup')
    expect(@http.size).to eq(4)
    expect_warning
  end
end
