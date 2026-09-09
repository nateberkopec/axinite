ENV.keys.grep(/\ASALESFORCE_/).each { |name| ENV.delete(name) }
require 'logger'
require 'rails'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'active_force'

module Acceptance
  class Application < Rails::Application
    config.root = File.expand_path('..', __dir__)
    config.eager_load = false
    config.secret_key_base = 'synthetic-acceptance-only-' * 4
    config.hosts = ['www.example.com']
    config.logger = Logger.new(File::NULL)
    config.active_job.queue_adapter = :inline
    config.action_dispatch.show_exceptions = Rails::VERSION::MAJOR >= 8 ? :none : false
  end
end
Acceptance::Application.initialize!
