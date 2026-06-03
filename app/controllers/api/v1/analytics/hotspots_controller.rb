module Api
  module V1
    module Analytics
      class HotspotsController < Api::V1::BaseController
        before_action -> { require_scope!("analytics:read") }
        before_action :load_geo_point!

        # GET /api/v1/analytics/hotspots?location_id=UUID&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD
        def index
          result = HotspotDetectionService.new(
            @geo_point,
            from: parse_date(params[:start_date]),
            to:   parse_date(params[:end_date])
          ).call

          render_ok({
            locationId:   @geo_point.id,
            locationName: @geo_point.name,
            hotspots:     result.hotspots.map { |h| serialize_hotspot(h) },
            meta: {
              totalEvents:    result.total_events,
              filteredEvents: result.filtered_events
            }
          })
        end

        private

        def load_geo_point!
          unless params[:location_id].present?
            render_error :unprocessable_entity, "location_id is required"
            throw :abort
          end

          @geo_point = GeoPoint
            .joins(:geo_project)
            .where(id: params[:location_id], geo_projects: { id: organization_projects })
            .first

          unless @geo_point
            render_error :not_found, "Location not found"
            throw :abort
          end
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

        def parse_date(value)
          Date.parse(value.to_s)
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
