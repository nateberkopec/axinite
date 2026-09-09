require 'axinite'

module Axinite
  module RSpec
    # Requiring this file never installs hooks. Call once from spec_helper.
    def self.install!(config, metadata: nil)
      filter = metadata ? [metadata] : []
      config.around(:each, *filter) do |example|
        Axinite.scan do
          example.run
          # RSpec records failures rather than propagating them from #run.
          Kernel.raise example.exception if example.exception
        end
      end
    end
  end
end
