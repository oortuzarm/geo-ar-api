module Api
  module Admin
    class UserSubscriptionsController < BaseController
      before_action :set_user

      # GET /api/admin/users/:user_id/subscription
      def show
        render json: subscription_json(@user)
      end

      # PATCH /api/admin/users/:user_id/subscription
      # Accepts any combination of: plan_id, subscription_status,
      # custom_location_limit, trial_starts_at, trial_ends_at.
      def update
        @user.update!(subscription_params)
        render json: subscription_json(@user)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def set_user
        @user = User.find(params[:user_id])
      end

      def subscription_params
        params.permit(
          :plan_id,
          :subscription_status,
          :custom_location_limit,
          :trial_starts_at,
          :trial_ends_at
        )
      end

      def subscription_json(user)
        limit = user.effective_location_limit
        {
          userId:                user.id,
          email:                 user.email,
          planId:                user.plan_id,
          planSlug:              user.plan&.slug,
          planName:              user.plan&.name,
          subscriptionStatus:    user.subscription_status,
          trialStartsAt:         user.trial_starts_at&.iso8601(3),
          trialEndsAt:           user.trial_ends_at&.iso8601(3),
          trialActive:           user.trial_active?,
          trialExpired:          user.trial_expired?,
          subscriptionActive:    user.subscription_active?,
          customLocationLimit:   user.custom_location_limit,
          effectiveLocationLimit: limit,
          currentLocationCount:  user.current_location_count,
          canCreateLocation:     user.can_create_location?
        }
      end
    end
  end
end
