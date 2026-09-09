require 'spec_helper'
require 'axinite/rspec'

RSpec.describe Axinite::RSpec do
  it 'does nothing merely by being required' do
    expect(Axinite.scan?).to be false
  end

  it 'preserves failures already recorded by RSpec' do
    config = double('config')
    failure = RuntimeError.new('original failure')
    example = double('example', exception: failure)
    expect(example).to receive(:run) { repeated_queries }
    expect(config).to receive(:around) do |&hook|
      Axinite.raise = true
      expect { hook.call(example) }.to raise_error { |error| expect(error).to equal(failure) }
    end
    described_class.install!(config)
    expect(Axinite.scan?).to be false
  end

  [nil, :axinite].each do |metadata|
    it "installs an explicit #{metadata || 'suite'} hook" do
      config = double('config')
      example = double('example', exception: nil)
      filter = metadata ? [metadata] : []
      expect(config).to receive(:around).with(:each, *filter) do |&hook|
        expect(example).to receive(:run) { expect(Axinite.scan?).to be true }
        hook.call(example)
      end
      described_class.install!(config, metadata: metadata)
      expect(Axinite.scan?).to be false
    end
  end
end
