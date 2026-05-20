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

        if user.id == current_user.id
          render json: { error: "No puedes eliminar tu propia cuenta." }, status: :forbidden
          return
        end

        if user.role == "admin" && User.where(role: "admin").count <= 1
          render json: { error: "No puedes eliminar al único administrador del sistema." }, status: :unprocessable_entity
          return
        end

        Rails.logger.info "[USER_DELETE] admin=#{current_user.id} target=#{user.id} email=#{user.email}"
        user.destroy!
        Rails.logger.info "[USER_DELETE] success target=#{user.id}"
        head :no_content

      rescue ActiveRecord::RecordNotFound
        render json: { error: "Usuario no encontrado." }, status: :not_found
      rescue ActiveRecord::RecordNotDestroyed => e
        Rails.logger.error "[USER_DELETE] RecordNotDestroyed user=#{user.id} — #{e.message}"
        render json: { error: "No se pudo eliminar el usuario." }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error "[USER_DELETE] #{e.class} user=#{user.id} — #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: "Error al eliminar el usuario. Revisa los logs." }, status: :internal_server_error
      end
    end
  end
end
