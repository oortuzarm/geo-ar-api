Rails.application.routes.draw do
  # ── Smart Proxy — root-level routes (NOT under /api/public/) ─────────────────
  # URL pattern: https://go.ubyca.com/proxy/:org_slug/:proxy_slug[/*path]
  # The controller lives in Api::Public but the path is intentionally at root
  # so the public URL is clean and future custom-domain routing can intercept here.
  get "proxy/:org_slug/:proxy_slug",        to: "api/public/smart_proxies#show",
                                            defaults: { path: "" }
  get "proxy/:org_slug/:proxy_slug/*path",  to: "api/public/smart_proxies#show"

  # Preflight for the analytics events endpoint (called from custom domains).
  match "api/public/smart_proxy_events", to: proc { [ 204, {}, [] ] }, via: :options

  # ── Ubyca API v1 ────────────────────────────────────────────────────────────
  namespace :api do
    namespace :v1 do
      get "health", to: "health#index"

      namespace :analytics do
        get :hotspots, to: "hotspots#index"
      end

      resources :projects, only: %i[index show] do
        resources :locations, only: %i[index], shallow: false
        member do
          get :analytics,                  to: "analytics#summary"
          get "analytics/locations",       to: "analytics#locations",    as: :analytics_locations
          get "analytics/distribution",    to: "analytics#distribution", as: :analytics_distribution
          get "analytics/intensity",       to: "analytics#intensity",     as: :analytics_intensity
          get "analytics/outside_areas",   to: "analytics#outside_areas", as: :analytics_outside_areas
        end
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
    # ── Studio analytics (session auth) ─────────────────────────────────────
    namespace :analytics do
      get :hotspots,      to: "hotspots#index"
      get :outside_areas, to: "outside_areas#index"
    end

    post   "auth/register",        to: "auth#register"
    post   "auth/login",           to: "auth#login"
    get    "auth/me",              to: "auth#me"
    delete "auth/logout",          to: "auth#logout"
    post   "auth/forgot_password", to: "auth#forgot_password"
    post   "auth/reset_password",  to: "auth#reset_password"

    namespace :public do
      resources :geo_projects, only: %i[show] do
        resources :geo_points, only: %i[index] do
          collection do
            get :session_visited_points
          end
          member do
            post :access
            post :complete_dwell
          end
        end
      end
      # Standalone heartbeat — not nested under geo_projects (no project context needed).
      post "geo_points/:id/live_visit",      to: "live_visits#create"
      # Project-level location ping — captures GPS regardless of active area membership.
      post "geo_projects/:id/live_location", to: "project_live_locations#create"
      get "settings", to: "settings#index"

      # Smart Proxy analytics events — emitted by the injected browser script
      post "smart_proxy_events", to: "smart_proxy_events#create"
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
        get :analytics_destinations,  to: "analytics_events#analytics_destinations"
        get :live_visits,             to: "live_visits#index"
        get :outside_sessions,          to: "live_visits#outside_sessions"
        get :inside_only_sessions,      to: "live_visits#inside_only_sessions"
        get :live_inside_positions,     to: "live_visits#live_inside_positions"
        get :live_outside_positions,    to: "live_visits#live_outside_positions"
        get :live_mixed_positions,      to: "live_visits#live_mixed_positions"
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

    resources :api_credentials, only: %i[index create update destroy] do
      member do
        post :regenerate_secret
      end
    end

    resources :analytics_events, only: %i[create]

    # Smart Proxies — Studio CRUD + analytics endpoints
    # Collection live_visits: org-level summary across all proxies.
    # Member routes mirror the shape of geo_project analytics endpoints so the
    # frontend can reuse the same components for both surfaces.
    resources :smart_proxies do
      collection do
        get  :live_visits                                             # org-level active sessions
        post :scan                                                    # compatibility scan without creating a proxy
      end
      member do
        get "live_visits",         to: "smart_proxies#proxy_live_visits",   as: :proxy_live_visits
        get "analytics",           to: "smart_proxies#analytics"
        get "analytics/intensity", to: "smart_proxies#analytics_intensity", as: :analytics_intensity
        get "hotspots",            to: "smart_proxies#proxy_hotspots",      as: :proxy_hotspots
      end
    end

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
