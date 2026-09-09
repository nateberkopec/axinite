class QueriesController < ActionController::Base
  if Rails.env.development? || Rails.env.test?
    around_action do |_controller, action|
      Axinite.scan { action.call }
    end
  end

  def show
    render json: Account.exercise(params.fetch(:operation))
  end
end
