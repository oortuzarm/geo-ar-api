module Api
  class AuthController < ApplicationController
    before_action :authenticate_user!, only: %i[me logout]

    # POST /api/auth/register
    def register
      user = User.create!(
        email:                 params[:email],
        password:              params[:password],
        password_confirmation: params[:password_confirmation],
        role:                  "user",
        status:                "active"
      )
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
