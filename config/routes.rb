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
      member do
        patch :sync
        get :analytics,          to: "analytics_events#stats"
        get :analytics_by_point, to: "analytics_events#stats_by_point"
        get :analytics_by_hour,  to: "analytics_events#by_hour"
        get :analytics_by_day,   to: "analytics_events#by_day"
        get :analytics_geo,      to: "analytics_events#geo_distribution"
      end
      resources :geo_points, only: %i[index create]
    end

    resources :analytics_events, only: %i[create]

    # Standalone update/delete for geo_points
    # (frontend calls PUT /api/geo_points/:id and DELETE /api/geo_points/:id)
    resources :geo_points, only: %i[update destroy]
  end

  get "/health", to: proc { [ 200, {}, [ "OK" ] ] }
end
