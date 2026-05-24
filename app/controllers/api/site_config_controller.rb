module Api
  class SiteConfigController < ApplicationController
    # GET /api/site_config
    # Public — no auth required. Called by /register to render trial days text.
    def show
      render json: {
        registerTrialDays: SiteConfig.get("register_trial_days", default: "14").to_i,
      }
    end
  end
end
