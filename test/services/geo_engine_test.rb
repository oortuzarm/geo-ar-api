require "test_helper"

class GeoEngineTest < ActiveSupport::TestCase
  # ── Haversine ──────────────────────────────────────────────────────────────

  test "haversine returns 0 for identical coordinates" do
    assert_in_delta 0, GeoEngine.haversine(-33.437, -70.650, -33.437, -70.650), 0.01
  end

  test "haversine returns approximately 111m for 0.001 degree latitude shift" do
    # 1 degree latitude ≈ 111,111 m; 0.001 degree ≈ 111 m
    dist = GeoEngine.haversine(-33.437, -70.650, -33.436, -70.650)
    assert_in_delta 111, dist, 5
  end

  # ── Radius boundary ────────────────────────────────────────────────────────

  test "inside_boundary? returns true when inside radius" do
    point = build_geo_point(lat: -33.437, lng: -70.650, radius: 100, mode: "radius")
    assert GeoEngine.inside_boundary?(point, -33.4372, -70.6501)
  end

  test "inside_boundary? returns false when outside radius" do
    point = build_geo_point(lat: -33.437, lng: -70.650, radius: 50, mode: "radius")
    refute GeoEngine.inside_boundary?(point, -33.438, -70.652)
  end

  # ── Polygon boundary ───────────────────────────────────────────────────────

  test "inside_boundary? returns true for point inside polygon" do
    polygon = square_polygon(-33.440, -70.655, -33.434, -70.645)
    point   = build_geo_point(lat: -33.437, lng: -70.650, mode: "polygon", polygon: polygon)
    assert GeoEngine.inside_boundary?(point, -33.437, -70.650)
  end

  test "inside_boundary? returns false for point outside polygon" do
    polygon = square_polygon(-33.440, -70.655, -33.434, -70.645)
    point   = build_geo_point(lat: -33.437, lng: -70.650, mode: "polygon", polygon: polygon)
    refute GeoEngine.inside_boundary?(point, -33.450, -70.680)
  end

  test "point_in_polygon? returns false for nil geojson" do
    refute GeoEngine.point_in_polygon?(-33.437, -70.650, nil)
  end

  test "point_in_polygon? returns false for invalid geojson" do
    refute GeoEngine.point_in_polygon?(-33.437, -70.650, { "type" => "NotAFeature" })
  end

  # ── Schedule ──────────────────────────────────────────────────────────────

  test "schedule_active? returns true when schedule disabled" do
    point = build_geo_point_with_schedule(enabled: false)
    assert GeoEngine.schedule_active?(point)
  end

  test "schedule_active? returns true when day and time are within window" do
    point = build_geo_point_with_schedule(
      enabled: true, days: %w[Lun Mar Mié Jue Vie],
      start: "09:00", finish: "18:00"
    )
    monday_at_noon = Time.new(2026, 6, 1, 12, 0, 0)  # 2026-06-01 is a Monday
    assert GeoEngine.schedule_active?(point, at: monday_at_noon)
  end

  test "schedule_active? returns false when day is not in schedule" do
    point = build_geo_point_with_schedule(
      enabled: true, days: %w[Lun Mar Mié Jue Vie],
      start: "09:00", finish: "18:00"
    )
    saturday = Time.new(2026, 6, 6, 12, 0, 0)  # 2026-06-06 is a Saturday
    refute GeoEngine.schedule_active?(point, at: saturday)
  end

  test "schedule_active? returns false when time is outside window" do
    point = build_geo_point_with_schedule(
      enabled: true, days: %w[Dom Lun Mar Mié Jue Vie Sáb],
      start: "09:00", finish: "18:00"
    )
    early = Time.new(2026, 6, 1, 8, 0, 0)
    refute GeoEngine.schedule_active?(point, at: early)
  end

  test "schedule_active? respects local_time override" do
    point = build_geo_point_with_schedule(
      enabled: true, days: %w[Dom Lun Mar Mié Jue Vie Sáb],
      start: "09:00", finish: "18:00"
    )
    # Server says 2am UTC but client says 15:00 local
    assert GeoEngine.schedule_active?(point, at: Time.new(2026, 6, 1, 2, 0, 0),
                                      local_day: "Lun", local_time: "15:00")
  end

  # ── Schedule (per-day schedule_rules format) ──────────────────────────────

  test "schedule_active? returns true when day has a rule and time is within window" do
    point = build_geo_point_with_schedule_rules(
      enabled: true,
      rules: [
        { "day" => "Lun", "start" => "09:00", "end" => "18:00" },
        { "day" => "Mar", "start" => "10:00", "end" => "20:00" }
      ]
    )
    monday_at_noon = Time.new(2026, 6, 1, 12, 0, 0)
    assert GeoEngine.schedule_active?(point, at: monday_at_noon, local_day: "Lun", local_time: "12:00")
  end

  test "schedule_active? returns false when today has no rule in schedule_rules" do
    point = build_geo_point_with_schedule_rules(
      enabled: true,
      rules: [{ "day" => "Lun", "start" => "09:00", "end" => "18:00" }]
    )
    tuesday = Time.new(2026, 6, 2, 12, 0, 0)
    refute GeoEngine.schedule_active?(point, at: tuesday, local_day: "Mar", local_time: "12:00")
  end

  test "schedule_active? returns false when time is outside the day rule window" do
    point = build_geo_point_with_schedule_rules(
      enabled: true,
      rules: [{ "day" => "Lun", "start" => "09:00", "end" => "18:00" }]
    )
    refute GeoEngine.schedule_active?(point, at: Time.new(2026, 6, 1, 0, 0, 0),
                                      local_day: "Lun", local_time: "08:30")
  end

  test "schedule_active? returns true at exact start of day rule window" do
    point = build_geo_point_with_schedule_rules(
      enabled: true,
      rules: [{ "day" => "Lun", "start" => "09:00", "end" => "18:00" }]
    )
    assert GeoEngine.schedule_active?(point, at: Time.new(2026, 6, 1, 0, 0, 0),
                                      local_day: "Lun", local_time: "09:00")
  end

  test "schedule_active? returns false at exact end of day rule window (exclusive)" do
    point = build_geo_point_with_schedule_rules(
      enabled: true,
      rules: [{ "day" => "Lun", "start" => "09:00", "end" => "18:00" }]
    )
    refute GeoEngine.schedule_active?(point, at: Time.new(2026, 6, 1, 0, 0, 0),
                                      local_day: "Lun", local_time: "18:00")
  end

  # ── Quota ──────────────────────────────────────────────────────────────────

  test "quota_available? returns true when quota not active" do
    point = build_geo_point_with_quota(enabled: false)
    assert GeoEngine.quota_available?(point)
  end

  test "quota_available? returns true when under limit" do
    point = build_geo_point_with_quota(enabled: true, limit: 100, used: 50)
    assert GeoEngine.quota_available?(point)
  end

  test "quota_available? returns false when limit reached" do
    point = build_geo_point_with_quota(enabled: true, limit: 10, used: 10)
    refute GeoEngine.quota_available?(point)
  end

  test "quota_remaining returns nil when quota not active" do
    point = build_geo_point_with_quota(enabled: false)
    assert_nil GeoEngine.quota_remaining(point)
  end

  test "quota_remaining returns correct count" do
    point = build_geo_point_with_quota(enabled: true, limit: 100, used: 37)
    assert_equal 63, GeoEngine.quota_remaining(point)
  end

  test "quota_remaining returns 0 when limit exceeded" do
    point = build_geo_point_with_quota(enabled: true, limit: 10, used: 10)
    assert_equal 0, GeoEngine.quota_remaining(point)
  end

  private

  # ── Helpers ────────────────────────────────────────────────────────────────

  def build_geo_point(lat:, lng:, radius: 50, mode: "radius", polygon: nil)
    p = GeoPoint.new(
      latitude:           lat,
      longitude:          lng,
      activation_radius:  radius,
      activation_mode:    mode,
      activation_polygon: polygon,
      availability:       {}
    )
    p.define_singleton_method(:requires_dwell_time) { false }
    p.define_singleton_method(:dwell_time_seconds)  { 0 }
    p
  end

  def build_geo_point_with_schedule(enabled:, days: [], start: nil, finish: nil)
    av = {
      "schedule_enabled"    => enabled,
      "schedule_days"       => days,
      "schedule_start_time" => start,
      "schedule_end_time"   => finish
    }
    GeoPoint.new(latitude: 0, longitude: 0, availability: av)
  end

  def build_geo_point_with_schedule_rules(enabled:, rules:)
    av = {
      "schedule_enabled" => enabled,
      "schedule_rules"   => rules
    }
    GeoPoint.new(latitude: 0, longitude: 0, availability: av)
  end

  def build_geo_point_with_quota(enabled:, limit: nil, used: 0)
    av = {
      "quota_enabled" => enabled,
      "quota_limit"   => limit,
      "quota_used"    => used
    }
    GeoPoint.new(latitude: 0, longitude: 0, availability: av)
  end

  # Creates a simple square GeoJSON Feature polygon.
  # Coordinates are [lng, lat] as per GeoJSON spec.
  def square_polygon(lat_min, lng_min, lat_max, lng_max)
    {
      "type" => "Feature",
      "geometry" => {
        "type" => "Polygon",
        "coordinates" => [[
          [ lng_min, lat_min ],
          [ lng_max, lat_min ],
          [ lng_max, lat_max ],
          [ lng_min, lat_max ],
          [ lng_min, lat_min ]
        ]]
      }
    }
  end
end
