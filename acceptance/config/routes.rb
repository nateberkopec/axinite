Rails.application.routes.draw do
  get '/queries/:operation', to: 'queries#show'
end
