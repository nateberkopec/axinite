ENV['RAILS_ENV'] = 'test'
require 'webmock/rspec'
WebMock.enable!
WebMock.disable_net_connect!
raise 'HTTP interception missing before boot' if Net::HTTP.equal?(WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP)
require_relative 'config/application'
require 'stringio'

module SalesforceHTTP
  def collection(records)
    { 'totalSize' => records.size, 'done' => true, 'records' => records }
  end

  def account_rows
    %w[a1 a2].map { |id| { 'attributes' => attributes('Account', id), 'Id' => id, 'Amount' => 3 } }
  end

  def contact_rows
    %w[a1 a2].map { |id| { 'attributes' => attributes('Contact', "c#{id}"), 'Id' => "c#{id}", 'AccountId' => id } }
  end

  def attributes(type, id)
    { 'type' => type, 'url' => "/services/data/v53.0/sobjects/#{type}/#{id}" }
  end

  # Independent, finite oracle: never derive expected SOQL from ActiveForce.
  def response_for(soql)
    accounts = account_rows
    contacts = contact_rows
    responses = {
      'SELECT Id, Amount FROM Account' => accounts,
      "SELECT Id, Amount FROM Account WHERE (Id IN ('a1','a2'))" => accounts,
      'SELECT Id, AccountId FROM Contact' => contacts,
      'SELECT Id, AccountId, Account.Id, Account.Amount FROM Contact' => contacts.map do |row|
        row.merge('Account' => accounts.find { |account| account['Id'] == row['AccountId'] })
      end,
      'SELECT Id, Amount, (SELECT Id, AccountId FROM Contacts) FROM Account' => accounts.map do |row|
        row.merge('Contacts' => collection(contacts.select { |child| child['AccountId'] == row['Id'] }))
      end,
      "SELECT count(Id) FROM Account WHERE (Id IN ('a1','a2'))" => [{ 'expr0' => 2 }],
      "SELECT sum(Amount) FROM Account WHERE (Id IN ('a1','a2'))" => [{ 'expr0' => 6 }]
    }
    %w[a1 a2].each do |id|
      ['', ' LIMIT 1'].each do |limit|
        responses["SELECT Id, Amount FROM Account WHERE (Id = '#{id}')#{limit}"] = accounts.select { |row| row['Id'] == id }
        responses["SELECT Id, AccountId FROM Contact WHERE (AccountId = '#{id}')#{limit}"] = contacts.select { |row| row['AccountId'] == id }
      end
      responses["SELECT count(Id) FROM Account WHERE (Id = '#{id}')"] = [{ 'expr0' => 1 }]
      responses["SELECT sum(Amount) FROM Account WHERE (Id = '#{id}')"] = [{ 'expr0' => 3 }]
    end
    collection(responses.fetch(soql) { raise ArgumentError, "Unexpected fixture SOQL: #{soql}" })
  end

  def request(operation)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get("/queries/#{operation}")
    expect(session.response.status).to eq(200)
    JSON.parse(session.response.body)
  end

  def start_transport
    @output = StringIO.new
    Axinite.custom_logger = Logger.new(@output)
    Axinite.rails_logger = false
    Axinite.raise = false
    ActiveForce.sfdc_client = Restforce.new(oauth_token: 'synthetic-token', instance_url: 'https://salesforce.invalid', api_version: '53.0')
    ActiveForce.composite_batch_query_threshold = 100_000
    @http = []
    @events = []
    @subscriber = ActiveSupport::Notifications.subscribe('query.active_force') { |*args| @events << args.last }
    stub_request(:get, %r{https://salesforce.invalid/services/data/v53.0/query\?})
      .with(headers: { 'Authorization' => 'OAuth synthetic-token' }).to_return do |http|
      soql = URI.decode_www_form(http.uri.query).to_h.fetch('q')
      @http << soql
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(response_for(soql)) }
    end
  end

  def stop_transport
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    Axinite.finish
    Axinite.raise = false
    Axinite.enabled = true
    Axinite.custom_logger = nil
    ActiveForce.composite_batch_query_threshold = 100_000
  end
end
