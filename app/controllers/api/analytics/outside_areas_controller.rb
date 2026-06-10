module Api
  module Analytics
    # Studio-internal "actividad fuera de áreas" endpoint.
    # Uses session/cookie auth (authenticate_user!) — not the API v1 Basic credential.
    # Delegates all business logic to Api::V1::ActivityOutsideAreasService.
    class OutsideAreasController < ApplicationController
      before_action :authenticate_user!
      before_action :load_and_authorize_project!

      # GET /api/analytics/outside_areas
      #   ?project_id=UUID
      #   &mode=historical|live          (default: historical)
      #   &start_date=YYYY-MM-DD         (historical only)
      #   &end_date=YYYY-MM-DD           (historical only)
      def index
        mode   = params[:mode].to_s == "live" ? :live : :historical
        result = Api::V1::ActivityOutsideAreasService.new(
          @project,
          mode: mode,
          from: parse_date(params[:start_date]),
          to:   parse_date(params[:end_date])
        ).call

        render json: {
          data: {
            mode:     mode,
            hotspots: result.hotspots.map { |h| serialize_hotspot(h) },
            meta: {
              totalPoints:          result.total_points,
              outsidePoints:        result.outside_points,
              activeGeoPointsCount: result.active_geo_points_count
            }
          }
        }
      end

      private

      def load_and_authorize_project!
        unless params[:project_id].present?
          render json: { error: "project_id is required" }, status: :unprocessable_entity
          throw :abort
        end

        @project = GeoProject.find_by(id: params[:project_id])

        unless @project
          render json: { error: "Project not found" }, status: :not_found
          throw :abort
        end

        authorize_project!(@project)
      end

      def parse_date(value)
        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def serialize_hotspot(hotspot)
        {
          lat:          hotspot.lat,
          lng:          hotspot.lng,
          count:        hotspot.count,
          intensity:    hotspot.intensity,
          radiusMeters: hotspot.radius_meters
        }
      end
    end
  end
end
