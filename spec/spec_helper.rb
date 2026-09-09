require 'axinite'

RSpec.configure do |config|
  config.after do
    Axinite.raise = false
    Axinite.custom_logger = nil
    Axinite.stderr_logger = false
    Axinite.rails_logger = false
    Axinite.axinite_logger = nil
    Axinite.backtrace_cleaner = nil
    Axinite.finish
    Axinite.enabled = true
    Axinite.min_n_queries = 2
    Axinite.ignore_queries = []
    Axinite.allow_stack_paths = []
    Axinite.ignore_pauses = false
    Axinite.stop_raise
  end
end

def query(soql = "SELECT Id FROM Contact WHERE AccountId = 'fake'", client_id: 1, **extra)
  ActiveSupport::Notifications.instrument('query.active_force', { soql: soql, model: Class.new, client_id: client_id, transport: :query }.merge(extra)) { :opaque_result }
end

def repeated_queries(count = 2, **options)
  count.times { query(**options) }
end
