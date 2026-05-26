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

      # GET /api/admin/users/:id
      def show
        user = User.find(params[:id])

        workspace = user.geo_projects.order(updated_at: :desc).first
        ws_count  = workspace ? GeoPoint.where(geo_project_id: workspace.id).count : 0

        cols = User.column_names

        render json: {
          id:                    user.id,
          email:                 user.email,
          firstName:             cols.include?("first_name") ? user.read_attribute(:first_name) : nil,
          lastName:              cols.include?("last_name")  ? user.read_attribute(:last_name)  : nil,
          company:               cols.include?("company")    ? user.read_attribute(:company)    : nil,
          jobTitle:              cols.include?("job_title")  ? user.read_attribute(:job_title)  : nil,
          country:               cols.include?("country")    ? user.read_attribute(:country)    : nil,
          role:                  user.role,
          status:                user.status,
          planId:                user.plan_id,
          planName:              user.plan&.name,
          subscriptionStatus:    user.subscription_status,
          trialEndsAt:           user.trial_ends_at&.iso8601(3),
          customLocationLimit:   user.custom_location_limit,
          effectiveLocationLimit: user.effective_location_limit,
          paddleCustomerId:      cols.include?("paddle_customer_id")     ? user.read_attribute(:paddle_customer_id)     : nil,
          paddleSubscriptionId:  cols.include?("paddle_subscription_id") ? user.read_attribute(:paddle_subscription_id) : nil,
          projectsCount:         user.geo_projects.count,
          pointsCount:           GeoPoint.joins(:geo_project).where(geo_projects: { user_id: user.id }).count,
          createdAt:             user.created_at.iso8601(3),
          updatedAt:             user.updated_at.iso8601(3),
          workspace:             workspace ? {
            id:          workspace.id,
            title:       workspace.title,
            status:      workspace.status,
            pointsCount: ws_count,
            updatedAt:   workspace.updated_at.iso8601(3)
          } : nil
        }

      rescue ActiveRecord::RecordNotFound
        render json: { error: "Usuario no encontrado." }, status: :not_found
      end

      # POST /api/admin/users
      def create
        # ── Input guards ──────────────────────────────────────────────────────
        email = params[:email].to_s.downcase.strip

        if email.blank?
          render json: { error: "El correo es obligatorio." }, status: :unprocessable_entity
          return
        end

        if User.exists?(email: email)
          render json: { error: "Ya existe un usuario con ese correo." }, status: :unprocessable_entity
          return
        end

        role          = params[:role].to_s.in?(User::ROLES)                          ? params[:role].to_s                : "user"
        acct_status   = params[:status].to_s.in?(User::STATUSES)                     ? params[:status].to_s              : "active"
        sub_status    = params[:subscription_status].to_s.in?(User::SUBSCRIPTION_STATUSES) ? params[:subscription_status].to_s : "trial"
        password_mode = params[:password_mode].to_s.presence || "auto"

        # ── Password ──────────────────────────────────────────────────────────
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

        # ── Build attrs (only core columns — always present) ──────────────────
        attrs = {
          email:                 email,
          password:              password,
          password_confirmation: confirmation,
          role:                  role,
          status:                acct_status,
          subscription_status:   sub_status,
          plan_id:               params[:plan_id].presence,
          trial_ends_at:         params[:trial_ends_at].presence,
          custom_location_limit: params[:custom_location_limit].presence&.to_i
        }

        # Profile columns added by migration 20260525000001.
        # Assign only when the columns actually exist so the controller
        # stays functional before the migration runs in a given environment.
        cols = User.column_names
        if cols.include?("first_name")
          attrs[:first_name] = params[:first_name].presence
          attrs[:last_name]  = params[:last_name].presence
          attrs[:company]    = params[:company].presence
          attrs[:job_title]  = params[:job_title].presence
          attrs[:country]    = params[:country].presence
        end
        if cols.include?("force_password_change")
          attrs[:force_password_change] =
            params[:force_password_change] == true || params[:force_password_change] == "true"
        end

        Rails.logger.info "[ADMIN_CREATE_USER] admin=#{current_user.id} email=#{email} mode=#{password_mode} " \
                          "role=#{role} status=#{acct_status} sub=#{sub_status} " \
                          "profile_cols=#{cols.include?('first_name')}"

        # ── Persist ───────────────────────────────────────────────────────────
        user = User.new(attrs)

        unless user.save
          msg = user.errors.full_messages.first || "Error de validación."
          Rails.logger.warn "[ADMIN_CREATE_USER] save failed email=#{email} errors=#{user.errors.full_messages}"
          render json: { error: msg }, status: :unprocessable_entity
          return
        end

        Rails.logger.info "[ADMIN_CREATE_USER] created user=#{user.id}"

        # ── Invitation email (auto mode only) ─────────────────────────────────
        if password_mode != "manual"
          begin
            token = PasswordResetToken.generate_for(user)
            PasswordResetMailer.send_invite_email(user: user, token: token)
          rescue => e
            Rails.logger.error "[ADMIN_CREATE_USER] invite email failed user=#{user.id}: #{e.class} #{e.message}"
            # Non-fatal: user is already created; email failure must not roll back
          end
        end

        # ── Response ──────────────────────────────────────────────────────────
        effective = user.custom_location_limit || user.plan&.location_limit
        render json: {
          id:                     user.id,
          email:                  user.email,
          role:                   user.role,
          status:                 user.status,
          planId:                 user.plan_id,
          planName:               user.plan&.name,
          planSlug:               user.plan&.slug,
          subscriptionStatus:     user.subscription_status,
          trialStartsAt:          user.trial_starts_at&.iso8601(3),
          trialEndsAt:            user.trial_ends_at&.iso8601(3),
          customLocationLimit:    user.custom_location_limit,
          effectiveLocationLimit: effective,
          projectsCount:          0,
          pointsCount:            0,
          createdAt:              user.created_at.iso8601(3),
          updatedAt:              user.updated_at.iso8601(3)
        }, status: :created

      rescue ActiveModel::UnknownAttributeError => e
        Rails.logger.error "[ADMIN_CREATE_USER] UnknownAttributeError — posible migración pendiente: #{e.message}"
        render json: { error: "Error de configuración interna (atributo desconocido). Revisar migraciones pendientes." },
               status: :unprocessable_entity

      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn "[ADMIN_CREATE_USER] RecordInvalid: #{e.message}"
        render json: { error: e.record.errors.full_messages.first || e.message }, status: :unprocessable_entity

      rescue => e
        Rails.logger.error "[ADMIN_CREATE_USER] #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
        render json: { error: "Error interno al crear el usuario. Revisar logs del servidor." },
               status: :internal_server_error
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
