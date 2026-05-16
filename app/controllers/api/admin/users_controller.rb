module Api
  module Admin
    class UsersController < BaseController
      # GET /api/admin/users
      def index
        users = User
          .left_joins(geo_projects: :geo_points)
          .left_joins(:plan)
          .select(
            "users.id, users.email, users.role, users.status",
            "users.subscription_status, users.trial_starts_at, users.trial_ends_at, users.custom_location_limit, users.plan_id",
            "users.created_at, users.updated_at",
            "plans.name AS plan_name, plans.slug AS plan_slug, plans.location_limit AS plan_location_limit",
            "COUNT(DISTINCT geo_projects.id) AS projects_count",
            "COUNT(geo_points.id) AS points_count"
          )
          .group("users.id, plans.id")
          .order("users.created_at DESC")

        render json: users.map { |u|
          effective = u.custom_location_limit || u.plan_location_limit
          {
            id:                    u.id,
            email:                 u.email,
            role:                  u.role,
            status:                u.status,
            planId:                u.plan_id,
            planName:              u.plan_name,
            planSlug:              u.plan_slug,
            subscriptionStatus:    u.subscription_status,
            trialStartsAt:         u.trial_starts_at&.iso8601(3),
            trialEndsAt:           u.trial_ends_at&.iso8601(3),
            customLocationLimit:   u.custom_location_limit,
            effectiveLocationLimit: effective,
            projectsCount:         u.projects_count.to_i,
            pointsCount:           u.points_count.to_i,
            createdAt:             u.created_at.iso8601(3),
            updatedAt:             u.updated_at.iso8601(3)
          }
        }
      end

      # DELETE /api/admin/users/:id
      def destroy
        user = User.find(params[:id])
        user.destroy!
        head :no_content
      end
    end
  end
end
