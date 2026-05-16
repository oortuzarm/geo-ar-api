module Api
  module Admin
    class PlansController < BaseController
      before_action :set_plan, only: %i[show update destroy]

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
        params.permit(
          :name,
          :slug,
          :monthly_price,
          :annual_discount_percent,
          :location_limit,
          :has_trial,
          :trial_days,
          :is_visible,
          :is_recommended,
          :apply_to_existing_users,
          :sort_order,
          :is_custom
        )
        # yearly_price_computed is intentionally excluded — computed automatically by the model.
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
          applyToExistingUsers: plan.apply_to_existing_users,
          sortOrder:            plan.sort_order,
          isCustom:             plan.is_custom,
          createdAt:            plan.created_at,
          updatedAt:            plan.updated_at
        }
      end
    end
  end
end
