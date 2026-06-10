require "test_helper"

class Api::V1::ActivityOutsideAreasServiceTest < ActiveSupport::TestCase
  # ── Setup ──────────────────────────────────────────────────────────────────────
  #
  # @project has two GeoPoints (active and inactive) both at the same 50 m radius.
  # All coordinate helpers below keep numbers simple — exact centre hits are used
  # so the Haversine distance is 0 m, well within any reasonable radius.

  setup do
    @user    = User.create!(email: "outside_svc_#{SecureRandom.hex(4)}@example.com",
                             password: "pw", role: "user", status: "active")
    @org     = Organization.create!(name: "OutsideSvc Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Outside Test", status: "active",
                                   user: @user, organization: @org)

    # Active GeoPoint — events inside here are EXCLUDED.
    @active_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Active Zone",
      latitude:          -34.0,
      longitude:         -58.0,
      activation_radius: 50,
      order:             0,
      active:            true
    )

    # Inactive GeoPoint — same location; events here are NOT grounds for exclusion.
    @inactive_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Inactive Zone",
      latitude:          -34.0,
      longitude:         -58.0,
      activation_radius: 50,
      order:             1,
      active:            false
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────────────────

  def make_event(lat, lng, date: Date.today)
    AnalyticsEvent.create!(
      geo_project: @project,
      geo_point:   @active_point,
      event_type:  "radius_enter",
      session_id:  SecureRandom.hex(8),
      event_date:  date,
      latitude:    lat,
      longitude:   lng
    )
  end

  def make_live_visit(lat, lng, geo_point: @active_point)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     geo_point,
      session_id:    SecureRandom.hex(8),
      lat:           lat,
      lng:           lng,
      inside_radius: true,
      last_seen_at:  Time.current
    )
  end

  def call_service(**opts)
    Api::V1::ActivityOutsideAreasService.new(@project, **opts).call
  end

  # ── Empty state ────────────────────────────────────────────────────────────────

  test "returns empty result when no events exist" do
    result = call_service
    assert_equal [], result.hotspots
    assert_equal 0,  result.total_points
    assert_equal 0,  result.outside_points
  end

  # ── Case 1: GeoPoint A active, event inside A → exclude ───────────────────────

  test "excludes event inside an active GeoPoint (Case 1)" do
    make_event(-34.0, -58.0)   # exact centre of @active_point (active, 50 m)
    result = call_service
    assert_equal 0, result.outside_points,
      "expected no outside events when GPS falls inside the only active GeoPoint"
  end

  # ── Case 2: GeoPoint A inactive, event inside A → include ─────────────────────

  test "includes event inside an inactive GeoPoint (Case 2)" do
    # Remove the active point so only the inactive one remains.
    @active_point.destroy

    make_event(-34.0, -58.0)   # inside @inactive_point only
    result = call_service
    assert_equal 1, result.outside_points,
      "expected event to be included when the only matching GeoPoint is inactive"
  end

  # ── Case 3: GeoPoint A active + GeoPoint B inactive, event inside both → exclude

  test "excludes event when at least one active GeoPoint contains it (Case 3)" do
    # Both @active_point (active) and @inactive_point (inactive) are at (-34.0, -58.0).
    make_event(-34.0, -58.0)   # inside both
    result = call_service
    assert_equal 0, result.outside_points,
      "expected exclusion because the active GeoPoint covers the coordinate"
  end

  # ── Case 4: GeoPoint A inactive + GeoPoint B inactive, event inside both → include

  test "includes event when all containing GeoPoints are inactive (Case 4)" do
    @active_point.update!(active: false)   # now both are inactive

    make_event(-34.0, -58.0)   # inside both (both inactive)
    result = call_service
    assert_equal 1, result.outside_points,
      "expected inclusion when every GeoPoint covering the coordinate is inactive"
  end

  # ── General outside logic ──────────────────────────────────────────────────────

  test "includes event far from all GeoPoints" do
    make_event(-35.0, -59.0)   # ~157 km from @active_point — well outside
    result = call_service
    assert_equal 1, result.outside_points
  end

  test "mixes inside and outside events correctly" do
    make_event(-34.0, -58.0)   # inside active GeoPoint → excluded
    make_event(-35.0, -59.0)   # outside all → included

    result = call_service
    assert_equal 2, result.total_points
    assert_equal 1, result.outside_points
  end

  test "reports active_geo_points_count correctly" do
    result = call_service
    assert_equal 1, result.active_geo_points_count,
      "expected exactly 1 active GeoPoint in the project"
  end

  # ── Coordinate sanitisation ────────────────────────────────────────────────────

  test "ignores events with nil coordinates" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "nil-coord",
      event_date: Date.today, latitude: nil, longitude: nil
    )
    assert_equal 0, call_service.total_points
  end

  test "ignores null-island coordinates (0, 0)" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "null-island",
      event_date: Date.today, latitude: 0, longitude: 0
    )
    assert_equal 0, call_service.total_points
  end

  # ── Date range filter (historical mode) ───────────────────────────────────────

  test "historical: respects from/to date range" do
    make_event(-35.0, -59.0, date: Date.new(2026, 1, 1))
    make_event(-35.0, -59.0, date: Date.new(2026, 3, 1))

    result = call_service(from: Date.new(2026, 2, 1))
    assert_equal 1, result.total_points
  end

  # ── Live mode ─────────────────────────────────────────────────────────────────

  test "live: excludes session inside an active GeoPoint" do
    make_live_visit(-34.0, -58.0)   # inside @active_point
    result = call_service(mode: :live)
    assert_equal 0, result.outside_points
  end

  test "live: includes session outside all active GeoPoints" do
    make_live_visit(-35.0, -59.0)   # far from all GeoPoints
    result = call_service(mode: :live)
    assert_equal 1, result.outside_points
  end

  test "live: only counts active_now sessions" do
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @active_point,
      session_id:    "stale-session",
      lat:           -35.0,
      lng:           -59.0,
      inside_radius: false,
      last_seen_at:  2.minutes.ago   # outside ACTIVE_WINDOW (45 s)
    )
    result = call_service(mode: :live)
    assert_equal 0, result.total_points
  end

  # ── Clustering ────────────────────────────────────────────────────────────────

  test "clusters nearby coordinates into a single hotspot" do
    make_event(-35.00001, -59.00001)
    make_event(-35.00002, -59.00002)   # rounds to same 4-decimal cell

    result = call_service
    assert_equal 1,  result.hotspots.size
    assert_equal 2,  result.hotspots.first.count
    assert_equal 1.0, result.hotspots.first.intensity
  end

  test "intensity is 1.0 for the hottest cell" do
    make_event(-35.0, -59.0)
    make_event(-35.0, -59.0)
    make_event(-36.0, -60.0)

    result  = call_service
    max_int = result.hotspots.map(&:intensity).max
    assert_equal 1.0, max_int
  end
end
