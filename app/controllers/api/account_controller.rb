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

    private

    def profile_params
      params.permit(:first_name, :last_name, :company, :job_title, :country)
    end

    def account_json(user)
      {
        id:        user.id,
        email:     user.email,
        firstName: user.first_name,
        lastName:  user.last_name,
        company:   user.company,
        jobTitle:  user.job_title,
        country:   user.country
      }
    end
  end
end
