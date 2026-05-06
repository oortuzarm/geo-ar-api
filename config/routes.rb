Rails.application.routes.draw do
  namespace :api do
    namespace :public do
      resources :geo_projects, only: %i[show create] do
        resources :geo_points, only: %i[index] do
          member { post :access }
        end
      end
    end

    resources :geo_projects do
      member { patch :sync }
      resources :geo_points, only: %i[index create]
    end

    # Standalone update/delete for geo_points
    # (frontend calls PUT /api/geo_points/:id and DELETE /api/geo_points/:id)
    resources :geo_points, only: %i[update destroy]
  end

  get "/health", to: proc { [200, { }, ["OK"]] }
end
