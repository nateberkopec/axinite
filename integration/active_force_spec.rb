require_relative '../spec/spec_helper'
require 'active_force'

# Entirely synthetic records and fake query transport.
module IntegrationModels
  class Account < ActiveForce::SObject
    self.table_name = 'Account'
    field :amount, from: 'Amount'
    has_many :contacts, model: 'IntegrationModels::Contact', foreign_key: :account_id
    has_one :primary_contact, model: 'IntegrationModels::Contact', foreign_key: :account_id
    has_many :named_contacts, model: 'IntegrationModels::Contact', foreign_key: :account_id,
                              scoped_as: -> { where(name: 'Fake') }
  end

  class Contact < ActiveForce::SObject
    self.table_name = 'Contact'
    field :account_id, from: 'AccountId'
    field :name, from: 'Name'
    belongs_to :account, model: Account, foreign_key: :account_id
  end
end

RSpec.describe 'Instrumented ActiveForce with Axinite (synthetic integration)' do
  let(:account) { IntegrationModels::Account }
  let(:contact) { IntegrationModels::Contact }
  let(:rows) { [Restforce::Mash.new('Id' => 'fake', 'Amount' => 3, 'expr0' => 3)] }
  let(:client) { double('fake client', query: rows) }

  before do
    @old_client = ActiveForce.sfdc_client
    @old_threshold = ActiveForce.composite_batch_query_threshold
    ActiveForce.sfdc_client = client
    ActiveForce.composite_batch_query_threshold = 100_000
  end

  after do
    ActiveForce.sfdc_client = @old_client
    ActiveForce.composite_batch_query_threshold = @old_threshold
  end

  def reports
    Axinite.scan
    yield
    Axinite.finish
  ensure
    Axinite.finish
  end

  [:contacts, :primary_contact, :named_contacts].each do |association|
    it "detects lazy #{association} across owners" do
      owners = %w[fake1 fake2].map { |id| account.new(id: id) }
      found = reports { owners.each { |owner| Array(owner.public_send(association)).map(&:id) } }
      expect(found.size).to eq(1)
      expect(found.first[:queries].size).to eq(2)
      expect(client).to have_received(:query).twice
    end

    it "eliminates #{association} repetition with includes" do
      relationship = account.find_association(association).sfdc_association_field
      data = %w[fake1 fake2].map do |id|
        Restforce::Mash.new('Id' => id, relationship => [Restforce::Mash.new('Id' => 'child', 'AccountId' => id)])
      end
      allow(client).to receive(:query).and_return(data)
      found = reports do
        account.includes(association).each { |owner| Array(owner.public_send(association)).map(&:id) }
      end
      expect(found).to be_empty
      expect(client).to have_received(:query).once
    end
  end

  it 'detects belongs_to, including identical foreign-key literals' do
    children = 2.times.map { contact.new(id: 'child', account_id: 'same') }
    found = reports { children.each { |child| child.account.id } }
    expect(found.size).to eq(1)
    expect(found.first[:queries].uniq.size).to eq(1)
  end

  it 'loads nested includes without follow-up association queries' do
    data = %w[fake1 fake2].map do |id|
      Restforce::Mash.new('Id' => id, 'Contacts' => [Restforce::Mash.new(
        'Id' => 'child', 'AccountId' => id, 'Account' => Restforce::Mash.new('Id' => id)
      )])
    end
    allow(client).to receive(:query).and_return(data)
    found = reports { account.includes(contacts: :account).each { |owner| owner.contacts.each { |child| child.account.id } } }
    expect(found).to be_empty
    expect(client).to have_received(:query).once
  end

  it 'fixes belongs_to with includes' do
    allow(client).to receive(:query).and_return(2.times.map do
      Restforce::Mash.new('Id' => 'child', 'AccountId' => 'same', 'Account' => Restforce::Mash.new('Id' => 'same'))
    end)
    expect(reports { contact.includes(:account).each { |child| child.account.id } }).to be_empty
    expect(client).to have_received(:query).once
  end

  [:to_a, :count, :sum].each do |operation|
    it "detects explicit repeated #{operation}" do
      values = []
      found = reports do
        2.times { values << account.where(id: 'same').public_send(operation, * (operation == :sum ? [:amount] : [])) }
      end
      expect(found.size).to eq(1)
      expect(values).to eq([3, 3]) unless operation == :to_a
    end
  end

  it 'groups currency magnitudes from the same stack through fake query transport' do
    found = reports { %w[USD100 USD200].each { |amount| account.where("Amount > #{amount}").to_a } }
    expect(found.size).to eq(1)
    expect(found.first[:queries]).to eq(['SELECT Id, Amount FROM Account WHERE (Amount > USD100)',
                                      'SELECT Id, Amount FROM Account WHERE (Amount > USD200)'])
    expect(client).to have_received(:query).twice
  end

  it 'keeps different currencies distinct on the same stack' do
    found = reports { %w[USD100 EUR200].each { |amount| account.where("Amount > #{amount}").to_a } }
    expect(found).to be_empty
  end

  it 'counts composite batches once each, without a blanket batching exemption' do
    ActiveForce.composite_batch_query_threshold = 1
    requests = Struct.new(:requests, :options).new([], { api_version: '53.0' })
    allow(client).to receive(:batch) do |&block|
      block.call(requests)
      [Restforce::Mash.new('statusCode' => 200, 'result' => rows)]
    end
    found = reports { 2.times { account.where(id: 'same').to_a } }
    expect(found.first[:queries].size).to eq(2)
    expect(client).to have_received(:batch).twice
    expect(client).not_to have_received(:query)
  end

  it 'does not execute lazy queries or reexecute loaded queries' do
    query = account.where(id: 'same')
    expect(reports { 2.times { query.to_s } }).to be_empty
    expect(client).not_to have_received(:query)
    expect(reports { 2.times { query.to_a } }).to be_empty
    expect(client).to have_received(:query).once
  end

  it 'enumerates real Restforce pages without counting pages as logical queries' do
    last_page = Restforce::Collection.new({ 'records' => [{ 'Id' => 'fake2' }] }, client)
    collection = Restforce::Collection.new({
      'records' => [{ 'Id' => 'fake1' }], 'nextRecordsUrl' => '/fake-next', 'totalSize' => 2
    }, client)
    allow(client).to receive(:query).and_return(collection)
    allow(client).to receive(:get).with('/fake-next').and_return(Struct.new(:body).new(last_page))
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('query.active_force') { |*args| events << args.last }
    found = reports { expect(account.all.map(&:id)).to eq(%w[fake1 fake2]) }
    expect(found).to be_empty
    expect(events.size).to eq(1)
    expect(client).to have_received(:get).once
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'preserves original failures and excludes rescued failed events' do
    failure = RuntimeError.new('synthetic failure')
    allow(client).to receive(:query).and_raise(failure)
    expect(reports { 2.times { begin; account.all; rescue RuntimeError; end } }).to be_empty
    Axinite.raise = true
    expect { Axinite.scan { account.all } }.to raise_error { |error| expect(error).to equal(failure) }
    expect(Axinite.scan?).to be(false)
  end

  it 'retains outer ownership and returns values through nested scans and pause' do
    found = reports do
      expect(Axinite.scan { :nested }).to eq(:nested)
      expect(Axinite.pause { 2.times { account.all }; :paused }).to eq(:paused)
      2.times { account.all }
    end
    expect(found.first[:queries].size).to eq(2)
  end

  it 'isolates fibers and threads from the owning scan' do
    found = reports do
      Fiber.new { 2.times { account.all }; expect(Axinite.scan?).to be(false) }.resume
      Thread.new { 2.times { account.all }; expect(Axinite.scan?).to be(false) }.value
    end
    expect(found).to be_empty
  end
end
