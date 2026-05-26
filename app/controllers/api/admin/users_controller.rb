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

      # POST /api/admin/users
      def create
        email = params[:email].to_s.downcase.strip

        if email.blank?
          render json: { error: "El correo es obligatorio." }, status: :unprocessable_entity
          return
        end

        if User.exists?(email: email)
          render json: { error: "Ya existe un usuario con ese correo." }, status: :unprocessable_entity
          return
        end

        role   = params[:role].to_s.in?(User::ROLES)                 ? params[:role]                : "user"
        status = params[:status].to_s.in?(User::STATUSES)            ? params[:status]              : "active"
        sub    = params[:subscription_status].to_s.in?(User::SUBSCRIPTION_STATUSES) ? params[:subscription_status] : "trial"

        password_mode = params[:password_mode].to_s

        if password_mode == "manual"
          password     = params[:password].to_s
          confirmation = params[:password_confirmation].to_s

          if password.length < 8
            render json: { error: "La contraseña debe tener al menos 8 caracteres." }, status: :unprocessable_entity
            return
          end

          if password != confirmation
            render json: { error: "Las contraseñas no coinciden." }, status: :unprocessable_entity
            return
          end
        else
          password     = SecureRandom.hex(16)
          confirmation = password
        end

        user = User.new(
          email:                 email,
          password:              password,
          password_confirmation: confirmation,
          role:                  role,
          status:                status,
          subscription_status:   sub,
          plan_id:               params[:plan_id].presence,
          trial_ends_at:         params[:trial_ends_at].presence,
          custom_location_limit: params[:custom_location_limit].presence&.to_i,
          first_name:            params[:first_name].presence,
          last_name:             params[:last_name].presence,
          company:               params[:company].presence,
          job_title:             params[:job_title].presence,
          country:               params[:country].presence,
          force_password_change: params[:force_password_change] == true || params[:force_password_change] == "true",
        )

        unless user.save
          render json: { error: user.errors.full_messages.first }, status: :unprocessable_entity
          return
        end

        Rails.logger.info "[ADMIN_CREATE_USER] admin=#{current_user.id} new_user=#{user.id} email=#{user.email} mode=#{password_mode}"

        if password_mode != "manual"
          begin
            token = PasswordResetToken.generate_for(user)
            PasswordResetMailer.send_invite_email(user: user, token: token)
          rescue => e
            Rails.logger.error "[ADMIN_CREATE_USER] invite email failed for #{user.id}: #{e.message}"
          end
        end

        effective = user.custom_location_limit || user.plan&.location_limit
        render json: {
          id:                    user.id,
          email:                 user.email,
          role:                  user.role,
          status:                user.status,
          planId:                user.plan_id,
          planName:              user.plan&.name,
          planSlug:              user.plan&.slug,
          subscriptionStatus:    user.subscription_status,
          trialStartsAt:         user.trial_starts_at&.iso8601(3),
          trialEndsAt:           user.trial_ends_at&.iso8601(3),
          customLocationLimit:   user.custom_location_limit,
          effectiveLocationLimit: effective,
          projectsCount:         0,
          pointsCount:           0,
          createdAt:             user.created_at.iso8601(3),
          updatedAt:             user.updated_at.iso8601(3),
        }, status: :created
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
