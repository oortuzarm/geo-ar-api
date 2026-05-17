module Api
  class PlansController < ApplicationController
    before_action :authenticate_user!

    # GET /api/plans
    # Returns visible plans for the authenticated user (non-admin).
    def index
      plans = Plan.where(is_visible: true).order(sort_order: :asc, created_at: :asc)
      render json: plans.map { |p| plan_json(p) }
    end

    private

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
