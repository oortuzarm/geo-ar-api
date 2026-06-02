module Api
  module V1
    class HealthController < ActionController::API
      def index
        render json: { status: "ok", version: "v1" }, status: :ok
      end
    end
  end
end
