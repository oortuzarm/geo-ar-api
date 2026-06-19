module Api
  module V1
    # Actividad registrada fuera de los GeoPoints activos del proyecto.
    #
    # A GPS coordinate is included in the result when NO active GeoPoint's
    # boundary contains it.  Uses GeoEngine.inside_boundary? — the same
    # Haversine (radius) and ray-casting (polygon) logic used everywhere else
    # on the platform.  Inactive GeoPoints are never checked.
    #
    # Modes:
    #   :historical — GPS coordinates from analytics_events with valid lat/lng
    #   :live       — GPS positions from GeoPointLiveVisit.active_now
    class ActivityOutsideAreasService
      PRECISION     = 4  # decimal degrees ≈ 11 m per grid cell
      CELL_RADIUS_M = 8  # display radius returned for each cluster dot

      Result  = Data.define(:hotspots, :total_points, :outside_points, :active_geo_points_count)
      Hotspot = Data.define(:lat, :lng, :count, :intensity, :radius_meters)

      def initialize(project, mode: :historical, from: nil, to: nil)
        @project = project
        @mode    = mode
        @from    = from
        @to      = to
      end

      def call
        active_points = @project.geo_points.where(active: true).to_a
        raw_coords    = fetch_coordinates

        outside_coords = raw_coords.reject { |lat, lng|
          active_points.any? { |point| GeoEngine.inside_boundary?(point, lat, lng) }
        }

        Result.new(
          hotspots:                cluster_and_normalize(outside_coords),
          total_points:            raw_coords.size,
          outside_points:          outside_coords.size,
          active_geo_points_count: active_points.size
        )
      end

      private

      def fetch_coordinates
        @mode == :live ? live_coordinates : historical_coordinates
      end

      # Live GPS positions from sessions active in the last ACTIVE_WINDOW.
      def live_coordinates
        ProjectLiveVisit
          .where(geo_project_id: @project.id)
          .active_now
          .where.not(lat: nil, lng: nil)
          .where("NOT (lat = 0 AND lng = 0)")
          .pluck(:lat, :lng)
      end

      # Historical GPS coordinates from project_location events only.
      # project_location is the only event type that captures the user's general
      # position regardless of whether they are inside or outside a GeoPoint.
      # Other event types (radius_enter, point_click, dwell_*) are only fired
      # when the user is already inside a boundary, so their coordinates cannot
      # represent outside activity and are excluded here.
      # Filters by optional date range via event_date.
      def historical_coordinates
        scope = AnalyticsEvent
          .where(geo_project_id: @project.id, event_type: "project_location")
          .where(had_outside_position: true)
          .where.not(latitude: nil, longitude: nil)
          .where(latitude: -90.0..90.0, longitude: -180.0..180.0)
          .where("NOT (latitude = 0 AND longitude = 0)")

        scope = scope.where(event_date: @from..) if @from
        scope = scope.where(event_date: ..@to)   if @to

        scope.pluck(:latitude, :longitude)
      end

      # Groups coordinates into grid cells, normalises intensity, sorts by count.
      def cluster_and_normalize(coords)
        return [] if coords.empty?

        buckets   = coords
          .group_by { |lat, lng| [lat.round(PRECISION), lng.round(PRECISION)] }
          .transform_values(&:count)
        max_count = buckets.values.max.to_f

        buckets
          .map { |(lat, lng), count|
            Hotspot.new(
              lat:           lat,
              lng:           lng,
              count:         count,
              intensity:     (count / max_count).round(4),
              radius_meters: CELL_RADIUS_M
            )
          }
          .sort_by { |h| -h.count }
      end
    end
  end
end
