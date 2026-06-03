module Api
  module V1
    class HotspotDetectionService
      # Grid precision: 4 decimal degrees ≈ 11m per cell at mid-latitudes.
      # Half-diagonal of a ~11m × ~9m cell ≈ 8m — used as the display radius.
      PRECISION     = 4
      CELL_RADIUS_M = 8

      Result  = Data.define(:hotspots, :total_points, :filtered_points)
      Hotspot = Data.define(:lat, :lng, :count, :intensity, :radius_meters)

      def initialize(geo_point, mode: :historical, from: nil, to: nil)
        @geo_point = geo_point
        @mode      = mode
        @from      = from
        @to        = to
      end

      def call
        raw, bounded = fetch_coordinates
        Result.new(
          hotspots:        cluster_and_normalize(bounded),
          total_points:    raw.size,
          filtered_points: bounded.size
        )
      end

      private

      def fetch_coordinates
        if @mode == :live
          coords = fetch_live_coordinates
          [coords, coords]  # inside_radius: true is already a boundary pre-filter
        else
          raw     = fetch_valid_coordinates
          bounded = filter_to_boundary(raw)
          [raw, bounded]
        end
      end

      # Live mode: active sessions currently inside the boundary.
      # GeoPointLiveVisit.inside_radius already ran GeoEngine — no second pass needed.
      # Excludes null island defensively since (0,0) validations allow that coordinate.
      def fetch_live_coordinates
        GeoPointLiveVisit
          .where(geo_point: @geo_point)
          .active_now
          .inside_radius
          .where.not(lat: nil, lng: nil)
          .where("NOT (lat = 0 AND lng = 0)")
          .pluck(:lat, :lng)
      end

      # Historical mode: fetch [lat, lng] pairs for radius_enter events with valid coordinates.
      # Excludes: nil, out-of-range, and null-island (0, 0) coordinates.
      def fetch_valid_coordinates
        scope = AnalyticsEvent
          .where(geo_point: @geo_point, event_type: "radius_enter")
          .where.not(latitude: nil, longitude: nil)
          .where(latitude: (-90.0..90.0), longitude: (-180.0..180.0))
          .where("NOT (latitude = 0 AND longitude = 0)")

        scope = scope.where(event_date: @from..) if @from
        scope = scope.where(event_date: ..@to)   if @to

        scope.pluck(:latitude, :longitude)
      end

      # Removes coordinates that fall outside the geo_point's boundary.
      # Works for both radius and polygon activation modes via GeoEngine.
      def filter_to_boundary(coords)
        coords.select { |lat, lng| GeoEngine.inside_boundary?(@geo_point, lat, lng) }
      end

      # Groups coordinates into grid cells, computes intensity, and sorts by count.
      def cluster_and_normalize(coords)
        return [] if coords.empty?

        buckets   = coords
          .group_by { |lat, lng| [lat.round(PRECISION), lng.round(PRECISION)] }
          .transform_values(&:count)
        max_count = buckets.values.max.to_f

        buckets
          .map { |(lat, lng), count|
            Hotspot.new(
              lat:          lat,
              lng:          lng,
              count:        count,
              intensity:    (count / max_count).round(4),
              radius_meters: CELL_RADIUS_M
            )
          }
          .sort_by { |h| -h.count }
      end
    end
  end
end
