module Api
  class AccountController < ApplicationController
    before_action :authenticate_user!

    # GET /api/account
    def show
      render json: account_json(current_user)
    end

    # PATCH /api/account
    # Allows updating profile fields only. Email and system role are immutable here.
    def update
      current_user.update!(profile_params)
      render json: account_json(current_user)
    end

    # PATCH /api/account/password
    def update_password
      unless current_user.authenticate(params[:current_password])
        render json: { error: "La contraseña actual no es correcta." }, status: :unauthorized
        return
      end

      if params[:password].blank? || params[:password].length < 8
        render json: { error: "La nueva contraseña debe tener al menos 8 caracteres." }, status: :unprocessable_entity
        return
      end

      if params[:password] != params[:password_confirmation]
        render json: { error: "Las contraseñas no coinciden." }, status: :unprocessable_entity
        return
      end

      current_user.update!(password: params[:password], password_confirmation: params[:password_confirmation])
      render json: { message: "Contraseña actualizada correctamente." }
    end

    private

    def profile_params
      params.permit(:first_name, :last_name, :company, :job_title, :country, :time_zone)
    end

    def account_json(user)
      {
        id:        user.id,
        email:     user.email,
        firstName: user.first_name,
        lastName:  user.last_name,
        company:   user.company,
        jobTitle:  user.job_title,
        country:   user.country,
        timeZone:  user.time_zone
      }
    end
  end
end
