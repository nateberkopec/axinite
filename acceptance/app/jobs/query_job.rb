class QueryJob < ActiveJob::Base
  if Rails.env.development? || Rails.env.test?
    around_perform do |_job, perform|
      Axinite.scan { perform.call }
    end
  end

  def perform(operation)
    Account.exercise(operation)
  end
end
