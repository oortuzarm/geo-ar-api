module Api
  class PlansController < ApplicationController
    # index is public — used by studio (authenticated) and by the landing page
    # (ubyca.com/precios, credentials: 'omit', no session cookie).
    skip_before_action :authenticate_user!, only: [:index], raise: false
    before_action :handle_landing_cors, only: [:index]

    # GET /api/plans
    def index
      plans = Plan.where(is_visible: true).order(sort_order: :asc, created_at: :asc)
      render json: plans.map { |p| plan_json(p) }
    end

    private

    # Belt-and-suspenders CORS for landing page origins.
    # rack-cors (position 0) should handle this, but explicit headers here survive
    # any middleware ordering or version quirks. Logged so Railway logs confirm receipt.
    def handle_landing_cors
      origin = request.headers["Origin"].to_s
      Rails.logger.info "[CORS_DEBUG] plans origin=#{origin.inspect} method=#{request.method}"
      return unless LANDING_ORIGINS.include?(origin)

      response.headers["Access-Control-Allow-Origin"]  = origin
      response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS, HEAD"
      response.headers["Access-Control-Allow-Headers"] = "Content-Type, Accept"
      response.headers["Vary"]                         = "Origin"
      Rails.logger.info "[CORS_DEBUG] plans → ACAO=#{origin}"
    end

    def plan_json(plan)
      {
        id:                    plan.id,
        name:                  plan.name,
        slug:                  plan.slug,
        monthlyPrice:          plan.monthly_price,
        annualDiscountPercent: plan.annual_discount_percent,
        yearlyPriceComputed:   plan.yearly_price_computed,
        locationLimit:         plan.location_limit,
        hasTrial:              plan.has_trial,
        trialDays:             plan.trial_days,
        isRecommended:         plan.is_recommended,
        isCustom:              plan.is_custom,
        sortOrder:             plan.sort_order,
      }
    end
  end
end
