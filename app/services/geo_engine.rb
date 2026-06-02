# GeoEngine — shared geospatial computation module.
#
# Single source of truth for all boundary, schedule, quota and dwell logic.
# Used by Public (Studio/app experience), API v1, and any future surface.
# All methods are pure computations except consume_quota!, which writes to DB.
module GeoEngine
  EARTH_RADIUS_METERS = 6_371_000.0
  WEEK_DAYS           = %w[Dom Lun Mar Mié Jue Vie Sáb].freeze
  private_constant :EARTH_RADIUS_METERS

  class << self
    # ── Distance ────────────────────────────────────────────────────────────

    def haversine(lat1, lng1, lat2, lng2)
      phi1 = lat1 * Math::PI / 180
      phi2 = lat2 * Math::PI / 180
      dphi = (lat2 - lat1) * Math::PI / 180
      dlam = (lng2 - lng1) * Math::PI / 180
      a    = Math.sin(dphi / 2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlam / 2)**2
      2 * EARTH_RADIUS_METERS * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end

    def distance_to(location, lat, lng)
      haversine(lat, lng, location.latitude, location.longitude)
    end

    # ── Boundary ─────────────────────────────────────────────────────────────

    # Returns true if (lat, lng) is inside the location's configured boundary.
    # Dispatches to radius or polygon depending on activation_mode.
    def inside_boundary?(location, lat, lng)
      case location.activation_mode
      when "radius"
        haversine(lat, lng, location.latitude, location.longitude) <= location.activation_radius
      when "polygon"
        point_in_polygon?(lat, lng, location.activation_polygon)
      else
        false
      end
    end

    # Ray-casting point-in-polygon against a GeoJSON Feature.
    # Supports Polygon and MultiPolygon geometries.
    # Ignores holes (inner rings) — sufficient for geofence use cases.
    def point_in_polygon?(lat, lng, geojson_feature)
      return false unless geojson_feature.is_a?(Hash)

      geometry = geojson_feature["geometry"]
      return false unless geometry.is_a?(Hash)

      case geometry["type"]
      when "Polygon"
        polygon_contains?(geometry["coordinates"], lng, lat)
      when "MultiPolygon"
        geometry["coordinates"].any? { |poly| polygon_contains?(poly, lng, lat) }
      else
        false
      end
    end

    # ── Schedule ─────────────────────────────────────────────────────────────

    # Returns true if the location's schedule allows access at the given time.
    #
    # Parameters:
    #   at:         — Time object (default: Time.current)
    #   local_day:  — Spanish day name override from the client (e.g. "Lun")
    #   local_time: — HH:MM time override from the client (e.g. "09:30")
    #
    # The local_* overrides exist so clients in different timezones can send
    # their local clock instead of relying on the server's UTC clock.
    def schedule_active?(location, at: Time.current, local_day: nil, local_time: nil)
      av = location.availability || {}
      return true unless av["schedule_enabled"]

      days = av["schedule_days"] || []

      today = if valid_local_day?(local_day)
        local_day
      else
        WEEK_DAYS[at.wday]
      end

      return false if days.any? && !days.include?(today)

      st = av["schedule_start_time"]
      et = av["schedule_end_time"]

      if st && et
        cur = if valid_local_time?(local_time)
          local_time
        else
          at.strftime("%H:%M")
        end
        # Open window is [start, end) — exclusive end time.
        return false if cur < st || cur >= et
      end

      true
    end

    # ── Quota ─────────────────────────────────────────────────────────────────

    def quota_active?(location)
      av = location.availability || {}
      av["quota_enabled"] && av["quota_limit"].present?
    end

    def quota_available?(location)
      return true unless quota_active?(location)
      av = location.availability || {}
      av["quota_used"].to_i < av["quota_limit"].to_i
    end

    def quota_remaining(location)
      return nil unless quota_active?(location)
      av = location.availability || {}
      [ av["quota_limit"].to_i - av["quota_used"].to_i, 0 ].max
    end

    # Atomically decrements quota_used by 1.
    # Returns true on success, false if quota is already exhausted.
    # Uses pessimistic row lock to prevent race conditions under concurrent requests.
    def consume_quota!(location)
      result = false
      GeoPoint.transaction do
        location.lock!
        location.reload
        av    = location.availability || {}
        limit = av["quota_limit"].to_i
        used  = av["quota_used"].to_i
        if used < limit
          av["quota_used"] = used + 1
          location.update_column(:availability, av)
          result = true
        else
          raise ActiveRecord::Rollback
        end
      end
      result
    end

    private

    def polygon_contains?(rings, x, y)
      outer_ring = rings&.first
      return false unless outer_ring.is_a?(Array)
      ray_casting(x, y, outer_ring)
    end

    # Classic ray-casting algorithm.
    # Shoots a horizontal ray from (x, y) to the right and counts edge crossings.
    # GeoJSON ring coordinates are [longitude, latitude] pairs, so x=lng, y=lat.
    def ray_casting(x, y, ring)
      n      = ring.size
      inside = false
      j      = n - 1
      n.times do |i|
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi).to_f + xi
          inside = !inside
        end
        j = i
      end
      inside
    end

    def valid_local_day?(value)
      WEEK_DAYS.include?(value)
    end

    def valid_local_time?(value)
      value.is_a?(String) && value.match?(/\A\d{2}:\d{2}\z/)
    end
  end
end
