require_relative 'support'
require 'axinite/rspec'

RSpec.configure do |config|
  config.include SalesforceHTTP
  config.before { start_transport; Axinite.raise = true }
  # One example per process: only the installed hook may finish its owned scan.
  case ENV.fetch('SCAN_MODE')
  when 'suite'
    Axinite::RSpec.install!(config)
  when 'metadata'
    Axinite::RSpec.install!(config, metadata: :axinite)
  end
end

RSpec.describe 'Rails-context explicit RSpec opt-in' do
  it 'executes real models without relying on controller scan callbacks', axinite: ENV['SELECTED'] == '1' do
    expect(Rails.application).to be_a(Rails::Application)
    Account.exercise('lookup')
    expect(@http.size).to eq(2)
    expect(@events.size).to eq(2)
    expect(Axinite.scan?).to eq(ENV['SCAN_MODE'] == 'suite' || (ENV['SCAN_MODE'] == 'metadata' && ENV['SELECTED'] == '1'))
    expect(:original).to eq(:failure) if ENV['EXAMPLE_FAILURE'] == '1'
  end
end
