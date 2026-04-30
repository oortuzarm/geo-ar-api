Rails.application.routes.draw do
  namespace :api do
    namespace :public do
      resources :geo_projects, only: [:show]
    end

    resources :geo_projects do
      resources :geo_points, only: %i[index create]
    end

    # Standalone update/delete for geo_points
    # (frontend calls PUT /api/geo_points/:id and DELETE /api/geo_points/:id)
    resources :geo_points, only: %i[update destroy]
  end

  get "/health", to: proc { [200, {}, ["ok"]] }
end
