module Api
  module Analytics
    # Studio-internal hotspots endpoint.  Uses session/cookie auth (authenticate_user!)
    # exactly like every other Studio analytics endpoint.  Delegates all detection
    # logic to Api::V1::HotspotDetectionService — no algorithm duplication.
    class HotspotsController < ApplicationController
      before_action :authenticate_user!
      before_action :load_and_authorize_point!

      # GET /api/analytics/hotspots
      #   ?location_id=UUID
      #   &mode=historical|live          (default: historical)
      #   &start_date=YYYY-MM-DD         (historical only)
      #   &end_date=YYYY-MM-DD           (historical only)
      def index
        mode   = parse_mode(params[:mode])
        result = Api::V1::HotspotDetectionService.new(
          @geo_point,
          mode: mode,
          from: parse_date(params[:start_date]),
          to:   parse_date(params[:end_date])
        ).call

        render json: {
          data: {
            locationId:   @geo_point.id,
            locationName: @geo_point.name,
            mode:         mode,
            hotspots:     result.hotspots.map { |h| serialize_hotspot(h) },
            meta: {
              totalPoints:    result.total_points,
              filteredPoints: result.filtered_points
            }
          }
        }
      end

      private

      def load_and_authorize_point!
        unless params[:location_id].present?
          render json: { error: "location_id is required" }, status: :unprocessable_entity
          throw :abort
        end

        @geo_point = GeoPoint.includes(:geo_project).find_by(id: params[:location_id])

        unless @geo_point
          render json: { error: "Location not found" }, status: :not_found
          throw :abort
        end

        authorize_project!(@geo_point.geo_project)
      end

      def parse_mode(value)
        value.to_s == "live" ? :live : :historical
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
