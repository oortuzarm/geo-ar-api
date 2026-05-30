module Api
  class AuthController < ApplicationController
    before_action :authenticate_user!, only: %i[me logout]

    # POST /api/auth/register
    def register
      onboarding_plan = Plan.find_by(is_onboarding_plan: true)
      plan_attrs      = resolve_onboarding_plan_attrs(onboarding_plan)

      user = nil
      ActiveRecord::Base.transaction do
        user = User.create!(
          email:                 params[:email],
          password:              params[:password],
          password_confirmation: params[:password_confirmation],
          role:                  "user",
          status:                "active",
          **plan_attrs
        )
        org = Organization.create!(name: "Mi organización")
        user.memberships.create!(organization: org, role: "owner")
      end
      session[:user_id] = user.id
      render json: user_json(user), status: :created
    end

    # POST /api/auth/login
    def login
      user = User.find_by(email: params[:email]&.downcase&.strip)

      if user.nil? || !user.authenticate(params[:password])
        render json: { error: "Credenciales inválidas" }, status: :unauthorized
        return
      end

      if user.status == "suspended"
        render json: { error: "Cuenta suspendida. Contactá al administrador." }, status: :forbidden
        return
      end

      session[:user_id] = user.id
      render json: user_json(user)
    end

    # GET /api/auth/me
    def me
      render json: user_json(current_user)
    end

    # DELETE /api/auth/logout
    def logout
      session.delete(:user_id)
      head :no_content
    end

    # POST /api/auth/forgot_password
    def forgot_password
      user = User.find_by(email: params[:email].to_s.downcase.strip)

      if user&.status == "active"
        token = PasswordResetToken.generate_for(user)
        PasswordResetMailer.send_reset_email(user: user, token: token)
      end

      render json: {
        message: "Si el correo existe en nuestra plataforma, te enviaremos instrucciones para recuperar tu contraseña."
      }
    end

    # POST /api/auth/reset_password
    def reset_password
      token_record = PasswordResetToken.find_valid(params[:token].to_s)

      if token_record.nil?
        render json: { error: "El link de recuperación es inválido o ya expiró." }, status: :unprocessable_entity
        return
      end

      password      = params[:password].to_s
      confirmation  = params[:password_confirmation].to_s

      if password.length < 8
        render json: { error: "La contraseña debe tener al menos 8 caracteres." }, status: :unprocessable_entity
        return
      end

      if password != confirmation
        render json: { error: "Las contraseñas no coinciden." }, status: :unprocessable_entity
        return
      end

      token_record.user.update!(password: password, password_confirmation: confirmation)
      token_record.use!

      render json: { message: "Contraseña actualizada correctamente. Ya podés iniciar sesión." }
    end

    private

    # Returns a hash of plan/trial attributes to merge into User.create! when a
    # valid onboarding plan is configured. Returns {} (no-op) otherwise so the
    # user is created safely with DB defaults (plan_id nil, effective_location_limit 0).
    def resolve_onboarding_plan_attrs(plan)
      unless plan
        Rails.logger.warn "[REGISTER] No onboarding plan configured — user created without plan assignment"
        return {}
      end

      unless plan.has_trial && plan.trial_days.to_i > 0
        Rails.logger.warn "[REGISTER] Onboarding plan '#{plan.slug}' has no valid trial " \
                          "(has_trial=#{plan.has_trial} trial_days=#{plan.trial_days.inspect}) " \
                          "— user created without plan assignment"
        return {}
      end

      now = Time.zone.now
      Rails.logger.info "[REGISTER] Assigning onboarding plan plan=#{plan.slug} " \
                        "trial_days=#{plan.trial_days} ends_at=#{(now + plan.trial_days.days).iso8601}"
      {
        plan_id:             plan.id,
        subscription_status: "trial",
        trial_starts_at:     now,
        trial_ends_at:       now + plan.trial_days.days
      }
    end

    def user_json(user)
      cols          = User.column_names
      trial_active  = user.trial_active?
      days_left = trial_active && user.trial_ends_at \
                    ? [ (user.trial_ends_at.to_date - Date.current).to_i, 0 ].max \
                    : nil
      {
        id:     user.id,
        email:  user.email,
        role:   user.role,
        status: user.status,
        planId:                 user.plan_id,
        subscriptionStatus:     user.subscription_status,
        trialStartsAt:          user.trial_starts_at&.iso8601,
        trialEndsAt:            user.trial_ends_at&.iso8601,
        trialActive:            trial_active,
        daysRemaining:          days_left,
        effectiveLocationLimit: user.effective_location_limit,
        planName:               user.plan&.name,
        planSlug:               user.plan&.slug,
        planFeaturesConfig:     user.plan&.effective_features_config,
        onboardingCompleted:    cols.include?("onboarding_completed") ? user.onboarding_completed : true
      }
    end
  end
end
