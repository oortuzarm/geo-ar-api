module Api
  module Admin
    class BaseController < ApplicationController
      before_action :authenticate_user!
      before_action :require_admin!

      private

      def require_admin!
        unless current_user.role == "admin"
          render json: { error: "No autorizado" }, status: :forbidden
          throw :abort
        end
      end
    end
  end
end
