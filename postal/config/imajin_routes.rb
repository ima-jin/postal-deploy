# frozen_string_literal: true

Rails.application.routes.append do
  scope "/imajin/v1", defaults: { format: :json } do
    post "domains", to: "imajin/domains#create"
    get "domains/:name", to: "imajin/domains#show", constraints: { name: /[^\/]+/ }
    post "domains/:name/check", to: "imajin/domains#check", constraints: { name: /[^\/]+/ }
  end
end
