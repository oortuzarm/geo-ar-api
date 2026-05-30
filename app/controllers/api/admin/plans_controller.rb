module Api
  module Admin
    class PlansController < BaseController
      before_action :set_plan, only: %i[show update destroy]

      # GET /api/admin/plan_feature_registry
      def feature_registry
        render json: Plan::FEATURE_REGISTRY
      end

      # GET /api/admin/plans
      def index
        plans = Plan.order(sort_order: :asc, created_at: :asc)
        render json: plans.map { |p| plan_json(p) }
      end

      # GET /api/admin/plans/:id
      def show
        render json: plan_json(@plan)
      end

      # POST /api/admin/plans
      def create
        plan = Plan.new(plan_params)
        plan.save!
        render json: plan_json(plan), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # PATCH /api/admin/plans/:id
      def update
        @plan.update!(plan_params)
        render json: plan_json(@plan)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # DELETE /api/admin/plans/:id
      # Hard-deletes the plan. Use PATCH is_visible=false to soft-hide instead.
      def destroy
        @plan.destroy!
        head :no_content
      end

      private

      def set_plan
        @plan = Plan.find(params[:id])
      end

      def plan_params
        permitted = params.permit(
          :name,
          :slug,
          :monthly_price,
          :annual_discount_percent,
          :location_limit,
          :has_trial,
          :trial_days,
          :is_visible,
          :is_recommended,
          :is_onboarding_plan,
          :apply_to_existing_users,
          :sort_order,
          :is_custom,
          :public_description,
          :cta_text,
          :cta_url,
          features: [],
          features_config: {}
        )
        # yearly_price_computed is intentionally excluded — computed automatically by the model.
        # Explicitly assign features when present so an empty array [] is not dropped by permit.
        permitted[:features] = Array.wrap(params[:features]).map(&:to_s) if params.key?(:features)
        # features_config: normalize_params already converted featuresConfig → features_config.
        # permit(features_config: {}) only allows scalar nested values, so content_types (array)
        # would be stripped. Override manually with the full hash via to_unsafe_h.
        if params.key?(:features_config)
          fc = case params[:features_config]
          when ActionController::Parameters then params[:features_config].to_unsafe_h
          when Hash                         then params[:features_config]
          end
          if fc
            permitted[:features_config] = fc
            Rails.logger.info "[PLAN_FEATURES_CONFIG] saving: #{fc.inspect}"
          end
        end
        permitted
      end

      def plan_json(plan)
        {
          id:                   plan.id,
          name:                 plan.name,
          slug:                 plan.slug,
          monthlyPrice:         plan.monthly_price,
          annualDiscountPercent: plan.annual_discount_percent,
          yearlyPriceComputed:  plan.yearly_price_computed,
          locationLimit:        plan.location_limit,
          hasTrial:             plan.has_trial,
          trialDays:            plan.trial_days,
          isVisible:            plan.is_visible,
          isRecommended:        plan.is_recommended,
          isOnboardingPlan:     plan.is_onboarding_plan,
          applyToExistingUsers: plan.apply_to_existing_users,
          sortOrder:            plan.sort_order,
          isCustom:             plan.is_custom,
          publicDescription:    plan.public_description,
          features:             plan.features || [],
          ctaText:              plan.cta_text,
          ctaUrl:               plan.cta_url,
          featuresConfig:       plan.effective_features_config,
          createdAt:            plan.created_at,
          updatedAt:            plan.updated_at
        }
      end
    end
  end
end
