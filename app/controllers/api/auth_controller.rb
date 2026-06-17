module Api
  class AuthController < ApplicationController
    include OnboardingPlanAssignment

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
          status:                "pending_email_verification",
          **plan_attrs
        )
        org = Organization.create!(name: "Mi organización")
        user.memberships.create!(organization: org, role: "owner")
      end

      code = user.generate_email_verification_code!
      EmailVerificationMailer.send_verification_email(user: user, code: code)

      render json: { status: "pending_verification", email: user.email }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[REGISTER_ERROR] #{e.record.errors.full_messages}")
      raise
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

      if user.status == "pending_email_verification"
        render json: {
          error: "Debes verificar tu correo electrónico antes de iniciar sesión.",
          code:  "email_not_verified",
          email: user.email
        }, status: :forbidden
        return
      end

      session[:user_id] = user.id
      render json: user_json(user)
    end

    # POST /api/auth/verify_email_code
    def verify_email_code
      user = User.find_by(email: params[:email]&.downcase&.strip)

      if user.nil? || user.status != "pending_email_verification"
        render json: { error: "No hay ninguna verificación pendiente para ese correo." }, status: :unprocessable_entity
        return
      end

      if user.email_verification_code_expired?
        render json: { error: "El código expiró. Solicitá uno nuevo.", code: "code_expired" }, status: :unprocessable_entity
        return
      end

      submitted = params[:code].to_s.strip
      unless ActiveSupport::SecurityUtils.secure_compare(user.email_verification_code.to_s, submitted)
        render json: { error: "Código incorrecto. Verificá e intentá de nuevo.", code: "invalid_code" }, status: :unprocessable_entity
        return
      end

      user.confirm_email!
      session[:user_id] = user.id
      render json: user_json(user)
    end

    # POST /api/auth/resend_verification_code
    def resend_verification_code
      user = User.find_by(email: params[:email]&.downcase&.strip)

      if user.nil? || user.status != "pending_email_verification"
        render json: { message: "Si ese correo está pendiente de verificación, recibirás un nuevo código." }
        return
      end

      code = user.generate_email_verification_code!
      EmailVerificationMailer.send_verification_email(user: user, code: code)

      render json: { message: "Código reenviado. Revisá tu correo." }
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
        apiAccessEnabled:       user.api_access_enabled?,
        apiCredentialsLimit:    user.effective_api_credentials_limit,
        onboardingCompleted:    cols.include?("onboarding_completed") ? user.onboarding_completed : true
      }
    end
  end
end
