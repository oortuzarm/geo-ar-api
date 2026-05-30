module Api
  class PlansController < ApplicationController
    # index is public — landing page (ubyca.com/precios) fetches it without a session.
    # start_trial requires an authenticated session (default authenticate_user! applies).
    before_action :authenticate_user!
    skip_before_action :authenticate_user!, only: [ :index ]
    before_action :handle_landing_cors, only: [ :index ]

    # GET /api/plans
    def index
      Rails.logger.info "[PLANS_PUBLIC] index reached without auth"
      plans = Plan.where(is_visible: true).order(sort_order: :asc, created_at: :asc)
      render json: plans.map { |p| plan_json(p) }
    end

    # POST /api/plans/:id/start_trial
    # Assigns the plan as a timed trial for the authenticated user.
    # Validates: plan has trial, user has no plan yet, user hasn't had a prior trial.
    def start_trial
      plan = Plan.find(params[:id])

      unless plan.has_trial && plan.trial_days.to_i > 0
        render json: { error: "Este plan no incluye prueba gratuita." }, status: :unprocessable_entity
        return
      end

      if current_user.plan_id.present?
        render json: { error: "Ya tienes un plan asignado." }, status: :unprocessable_entity
        return
      end

      if current_user.trial_starts_at.present?
        render json: { error: "Ya utilizaste tu prueba gratuita anteriormente." }, status: :unprocessable_entity
        return
      end

      now = Time.zone.now
      current_user.update!(
        plan_id:             plan.id,
        subscription_status: "trial",
        trial_starts_at:     now,
        trial_ends_at:       now + plan.trial_days.days
      )

      Rails.logger.info "[START_TRIAL] user_id=#{current_user.id} plan=#{plan.slug} " \
                        "ends_at=#{current_user.trial_ends_at.iso8601}"

      render json: { success: true }, status: :ok
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Plan no encontrado." }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
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
        isOnboardingPlan:      plan.is_onboarding_plan,
        isCustom:              plan.is_custom,
        sortOrder:             plan.sort_order,
        publicDescription:     plan.public_description,
        features:              plan.features || [],
        ctaText:               plan.cta_text,
        ctaUrl:                plan.cta_url,
        featuresConfig:        plan.effective_features_config
      }
    end
  end
end
