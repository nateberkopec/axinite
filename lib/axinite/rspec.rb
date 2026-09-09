require 'axinite'

module Axinite
  module RSpec
    # Requiring this file never installs hooks. Call once from spec_helper BEFORE
    # defining any example groups: this registration does not update existing groups.
    def self.install!(config, metadata: nil)
      unless defined?(::RSpec::Core::Version::STRING) &&
          ::RSpec::Core::Version::STRING.match?(/\A3\.13\./) &&
          config.respond_to?(:hooks) && config.hooks.respond_to?(:register)
        raise ArgumentError, 'Axinite RSpec integration requires rspec-core 3.13.x and its hooks.register interface'
      end

      filter = metadata ? [metadata] : []
      # RSpec 3.13's public #around prepends, placing us INSIDE its built-in
      # aggregation hook. This one private registration encloses aggregation so
      # failures are recorded before we decide to report. Recheck on RSpec upgrades.
      config.hooks.register(:append, :around, :each, *filter) do |example|
        Axinite.scan do
          example.run
          # RSpec records failures and runtime skips rather than propagating them.
          break if example.exception || example.execution_result.pending_exception || example.metadata[:skip]
        end
      end
    end
  end
end
