Rails.application.routes.draw do
  # ── Ubyca API v1 ────────────────────────────────────────────────────────────
  namespace :api do
    namespace :v1 do
      get "health", to: "health#index"

      resources :projects, only: %i[index show] do
        resources :locations, only: %i[index], shallow: false
      end

      resources :locations, only: %i[show]

      namespace :presence do
        post :validate
        post :check
      end
    end
  end

  # ── Existing API (Studio / Public) ───────────────────────────────────────────
  namespace :api do
    post   "auth/register",        to: "auth#register"
    post   "auth/login",           to: "auth#login"
    get    "auth/me",              to: "auth#me"
    delete "auth/logout",          to: "auth#logout"
    post   "auth/forgot_password", to: "auth#forgot_password"
    post   "auth/reset_password",  to: "auth#reset_password"

    namespace :public do
      resources :geo_projects, only: %i[show] do
        resources :geo_points, only: %i[index] do
          member do
            post :access
            post :complete_dwell
          end
        end
      end
      # Standalone heartbeat — not nested under geo_projects (no project context needed).
      post "geo_points/:id/live_visit", to: "live_visits#create"
      get "settings", to: "settings#index"
    end

    resources :geo_projects do
      member do
        patch :sync
        get :analytics,               to: "analytics_events#stats"
        get :analytics_by_point,      to: "analytics_events#stats_by_point"
        get :analytics_by_hour,       to: "analytics_events#by_hour"
        get :analytics_by_day,        to: "analytics_events#by_day"
        get :analytics_geo,           to: "analytics_events#geo_distribution"
        get :historical_intensity,    to: "analytics_events#historical_intensity"
        get :live_visits,             to: "live_visits#index"
      end
      resources :geo_points, only: %i[index create]
    end

    namespace :admin do
      resources :users, only: %i[index show create destroy] do
        resource :subscription, only: %i[show update], controller: "user_subscriptions"
      end
      resources :projects, only: %i[index] do
        member { patch :community_status, to: "projects#update_community_status" }
      end
      get :metrics,  to: "metrics#index"
      resources :plans, only: %i[index show create update destroy]
      get :plan_feature_registry, to: "plans#feature_registry"
      resources :site_configs, only: %i[update]
      get   "settings", to: "settings#index"
      patch "settings", to: "settings#update"
      resources :onboarding_categories, only: %i[index create update destroy]
      resources :onboarding_options,    only: %i[index create update destroy] do
        collection { patch :reorder }
      end
      get "onboarding/metrics", to: "onboarding_metrics#index"
    end

    get  "onboarding/config", to: "onboarding#index"
    post "onboarding",        to: "onboarding#submit"

    resources :plans, only: %i[index] do
      member do
        post :start_trial
      end
    end
    get "site_config", to: "site_config#show"

    namespace :community do
      get :projects, to: "projects#index"
    end

    get   "account",          to: "account#show"
    patch "account",          to: "account#update"
    patch "account/password", to: "account#update_password"

    # Temporary previews — create/show/destroy are public; claim requires auth.
    resources :temporary_previews, only: %i[create show destroy], param: :token do
      member do
        post :claim
      end
    end

    resources :analytics_events, only: %i[create]

    # Standalone update/delete for geo_points
    # (frontend calls PUT /api/geo_points/:id and DELETE /api/geo_points/:id)
    resources :geo_points, only: %i[update destroy]

    resources :members, only: %i[index update destroy]

    resources :invitations, only: %i[create destroy] do
      member do
        post :resend
      end
      collection do
        get  "accept/:token", action: :show_accept, as: :accept_preview
        post :accept
      end
    end
  end

  get "/health", to: proc { [ 200, {}, [ "OK" ] ] }
end
