# Hotspot detection for Smart Proxy — same algorithm and output shape as
# Api::V1::HotspotDetectionService, but sourced from SmartProxyLiveVisit
# (live mode) and analytics_events with smart_proxy_id (historical mode)
# instead of GeoPoint / GeoPointLiveVisit.
#
# Output is intentionally identical so the frontend can render both surfaces
# with the same hotspot component.
class SmartProxyHotspotService
  PRECISION     = 4   # decimal degrees ≈ 11 m per cell
  CELL_RADIUS_M = 8   # display radius for each cluster dot

  Result  = Data.define(:hotspots, :total_points, :filtered_points)
  Hotspot = Data.define(:lat, :lng, :count, :intensity, :radius_meters)

  # Historical events that carry GPS coordinates (heartbeat is the main source
  # since it fires every 30 s and always includes the latest watchPosition fix).
  COORDINATE_EVENT_TYPES = %w[
    smart_proxy_heartbeat
    smart_proxy_location_granted
  ].freeze
  private_constant :COORDINATE_EVENT_TYPES, :PRECISION, :CELL_RADIUS_M

  def initialize(smart_proxy, mode: :historical, from: nil, to: nil)
    @smart_proxy = smart_proxy
    @mode        = mode
    @from        = from
    @to          = to
  end

  def call
    coords = fetch_coordinates
    Result.new(
      hotspots:        cluster_and_normalize(coords),
      total_points:    coords.size,
      filtered_points: coords.size
    )
  end

  private

  def fetch_coordinates
    @mode == :live ? live_coordinates : historical_coordinates
  end

  # Live mode: current watchPosition fixes from active sessions (same 45 s window
  # as GeoPointLiveVisit).  SmartProxyLiveVisit is upserted on every heartbeat
  # so its lat/lng is always the most recent GPS fix for that session.
  def live_coordinates
    @smart_proxy.smart_proxy_live_visits
      .active_now
      .where.not(lat: nil, lng: nil)
      .where("NOT (lat = 0 AND lng = 0)")
      .pluck(:lat, :lng)
  end

  # Historical mode: heartbeat and location_granted events carry lat/lng sent
  # by the watchPosition callback in the injected script.
  def historical_coordinates
    scope = AnalyticsEvent
      .where(smart_proxy_id: @smart_proxy.id,
             event_type:     COORDINATE_EVENT_TYPES)
      .where.not(latitude: nil, longitude: nil)
      .where(latitude: -90.0..90.0, longitude: -180.0..180.0)
      .where("NOT (latitude = 0 AND longitude = 0)")

    scope = scope.where(event_date: @from..) if @from
    scope = scope.where(event_date: ..@to)   if @to

    scope.pluck(:latitude, :longitude)
  end

  # Grid-based clustering identical to HotspotDetectionService.
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
