module Api
  class AuthController < ApplicationController
    before_action :authenticate_user!, only: %i[me logout]

    # POST /api/auth/register
    def register
      user = nil
      ActiveRecord::Base.transaction do
        user = User.create!(
          email:                 params[:email],
          password:              params[:password],
          password_confirmation: params[:password_confirmation],
          role:                  "user",
          status:                "active"
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

    def user_json(user)
      {
        id:     user.id,
        email:  user.email,
        role:   user.role,
        status: user.status
      }
    end
  end
end
