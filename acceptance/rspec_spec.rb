require 'open3'
require 'timeout'
require 'rbconfig'

RSpec.describe 'Explicit RSpec installation in a real Rails context' do
  def run_ruby(environment, *arguments)
    output = nil
    status = nil
    Open3.popen2e(environment, RbConfig.ruby, *arguments) do |input, stream, wait|
      input.close
      begin
        Timeout.timeout(30) { output = stream.read; status = wait.value }
      rescue Timeout::Error
        Process.kill('KILL', wait.pid)
        raise
      end
    end
    [output, status]
  end

  def run_fixture(environment)
    run_ruby(environment, '-S', 'rspec', 'acceptance/rspec_fixture.rb', '--no-color')
  end

  it 'boots production without loading the development detector' do
    source = <<~RUBY
      require 'webmock'
      WebMock.enable!
      WebMock.disable_net_connect!
      abort 'HTTP interception missing before boot' if Net::HTTP.equal?(WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP)
      require File.expand_path('acceptance/config/application')
      abort 'development gem available in production' if Gem.loaded_specs.key?('axinite')
      abort 'Axinite loaded in production' if defined?(Axinite) && Axinite.respond_to?(:scan)
      abort 'Axinite source loaded' if $LOADED_FEATURES.any? { |path| path.end_with?('/lib/axinite.rb') }
      puts Rails.env
    RUBY
    output, status = run_ruby({ 'RAILS_ENV' => 'production', 'BUNDLE_WITHOUT' => 'development:test' }, '-e', source)
    expect(status.success?).to be(true), output
    expect(output).to include('production')
  end

  it 'boots development with explicit configuration but no active scan' do
    source = <<~RUBY
      require 'webmock'
      WebMock.enable!
      WebMock.disable_net_connect!
      abort 'HTTP interception missing before boot' if Net::HTTP.equal?(WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP)
      require File.expand_path('acceptance/config/application')
      abort 'unexpected scan' if Axinite.scan?
      abort 'missing logger configuration' unless Axinite.rails_logger
      puts Rails.env
    RUBY
    output, status = run_ruby({ 'RAILS_ENV' => 'development' }, '-e', source)
    expect(status.success?).to be(true), output
    expect(output).to include('development')
  end

  [['suite', '0', true], ['metadata', '1', true], ['metadata', '0', false], ['none', '1', false]].each do |mode, selected, fails|
    it "honors #{mode} opt-in with selected=#{selected}" do
      output, status = run_fixture('SCAN_MODE' => mode, 'SELECTED' => selected, 'EXAMPLE_FAILURE' => '0')
      expect(status.success?).to eq(!fails), output
      expect(output).to include(fails ? '1 example, 1 failure' : '1 example, 0 failures')
      if fails
        expect(output).to include('NPlusOneQueriesError', '2 logical executions', 'app/models/account.rb')
      else
        expect(output).not_to include('NPlusOneQueriesError')
      end
    end
  end

  it 'preserves an original RSpec failure instead of a secondary N+1 error' do
    output, status = run_fixture('SCAN_MODE' => 'suite', 'SELECTED' => '1', 'EXAMPLE_FAILURE' => '1')
    expect(status.success?).to be(false)
    expect(output).to include('1 example, 1 failure', 'expected: :failure')
    expect(output).not_to include('NPlusOneQueriesError')
  end
end
