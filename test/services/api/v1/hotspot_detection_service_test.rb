require "test_helper"

class Api::V1::HotspotDetectionServiceTest < ActiveSupport::TestCase
  # ── Setup ─────────────────────────────────────────────────────────────────────
  # @point uses default activation_mode "radius" with 50m radius.
  # All test coordinates within 43m of center (-34.0, -58.0) are inside boundary.

  setup do
    @user    = User.create!(email:    "svc_#{SecureRandom.hex(4)}@example.com",
                             password: "pw", role: "user", status: "active")
    @project = GeoProject.create!(title: "SvcTest", status: "active", user: @user)
    @point   = GeoPoint.create!(geo_project: @project, name: "Zone",
                                 latitude: -34.0, longitude: -58.0, order: 0)
  end

  # Creates a radius_enter AnalyticsEvent with the given coordinates.
  def make_event(lat, lng, date: Date.today)
    AnalyticsEvent.create!(
      geo_project: @project,
      geo_point:   @point,
      event_type:  "radius_enter",
      session_id:  SecureRandom.hex(8),
      event_date:  date,
      latitude:    lat,
      longitude:   lng
    )
  end

  def call_service(point = @point, **opts)
    Api::V1::HotspotDetectionService.new(point, **opts).call
  end

  # ── Empty state ───────────────────────────────────────────────────────────────

  test "returns empty result when no events exist" do
    result = call_service
    assert_equal [], result.hotspots
    assert_equal 0,  result.total_points
    assert_equal 0,  result.filtered_points
  end

  # ── Coordinate filtering ──────────────────────────────────────────────────────

  test "excludes events with nil latitude" do
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "nil-lat",
                            event_date: Date.today, latitude: nil, longitude: -58.0)
    assert_equal 0, call_service.total_points
  end

  test "excludes events with nil longitude" do
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "nil-lng",
                            event_date: Date.today, latitude: -34.0, longitude: nil)
    assert_equal 0, call_service.total_points
  end

  test "excludes null island coordinates (0.0, 0.0)" do
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "null-island",
                            event_date: Date.today, latitude: 0.0, longitude: 0.0)
    assert_equal 0, call_service.total_points
  end

  test "does not exclude valid coordinates on lat=0 when lng is nonzero" do
    # Equator coordinates are valid — null island filter only blocks (0, 0)
    eq_point = GeoPoint.create!(geo_project: @project, name: "Equator",
                                 latitude: 0.0, longitude: 10.0, order: 99)
    AnalyticsEvent.create!(geo_project: @project, geo_point: eq_point,
                            event_type: "radius_enter", session_id: "equator",
                            event_date: Date.today, latitude: 0.0001, longitude: 10.0001)
    result = Api::V1::HotspotDetectionService.new(eq_point).call
    assert_equal 1, result.total_points
  end

  # ── Clustering ────────────────────────────────────────────────────────────────

  test "single event produces one hotspot with intensity 1.0 and count 1" do
    make_event(-34.0001, -58.0001)
    result = call_service
    assert_equal 1,   result.hotspots.size
    assert_equal 1,   result.hotspots.first.count
    assert_equal 1.0, result.hotspots.first.intensity
  end

  test "clusters events that round to the same 4-decimal grid cell" do
    make_event(-34.00011, -58.00011)  # rounds to -34.0001, -58.0001
    make_event(-34.00012, -58.00012)  # rounds to -34.0001, -58.0001
    result = call_service
    assert_equal 1, result.hotspots.size
    assert_equal 2, result.hotspots.first.count
  end

  test "separates events in different grid cells" do
    make_event(-34.0001, -58.0001)  # cell A (~14m from center)
    make_event(-34.0002, -58.0002)  # cell B (~29m from center)
    result = call_service
    assert_equal 2, result.hotspots.size
  end

  test "sorts hotspots by count descending" do
    3.times { make_event(-34.0001, -58.0001) }
    1.times { make_event(-34.0002, -58.0002) }
    counts = call_service.hotspots.map(&:count)
    assert_equal counts.sort.reverse, counts
  end

  # ── Intensity normalization ───────────────────────────────────────────────────

  test "hotspot with most events has intensity 1.0" do
    3.times { make_event(-34.0001, -58.0001) }
    1.times { make_event(-34.0002, -58.0002) }
    assert_equal 1.0, call_service.hotspots.first.intensity
  end

  test "intensity is proportional to relative count" do
    6.times { make_event(-34.0001, -58.0001) }
    2.times { make_event(-34.0002, -58.0002) }
    result = call_service
    assert_equal   1.0,    result.hotspots[0].intensity
    assert_in_delta 0.3333, result.hotspots[1].intensity, 0.001
  end

  test "intensity is between 0.0 and 1.0 for all hotspots" do
    3.times { make_event(-34.0001, -58.0001) }
    2.times { make_event(-34.0002, -58.0002) }
    1.times { make_event(-34.0003, -58.0003) }
    call_service.hotspots.each do |h|
      assert h.intensity >= 0.0
      assert h.intensity <= 1.0
    end
  end

  # ── Date range filtering ──────────────────────────────────────────────────────

  test "filters by from date (inclusive)" do
    make_event(-34.0001, -58.0001, date: Date.new(2025, 1, 1))
    make_event(-34.0001, -58.0001, date: Date.today)
    assert_equal 1, call_service(from: Date.today).total_points
  end

  test "filters by to date (inclusive)" do
    make_event(-34.0001, -58.0001, date: Date.new(2025, 1, 1))
    make_event(-34.0001, -58.0001, date: Date.today)
    assert_equal 1, call_service(to: Date.new(2025, 12, 31)).total_points
  end

  test "includes all events when no date range is given" do
    make_event(-34.0001, -58.0001, date: Date.new(2025, 6, 1))
    make_event(-34.0001, -58.0001, date: Date.today)
    assert_equal 2, call_service.total_points
  end

  # ── Boundary filtering ────────────────────────────────────────────────────────

  test "excludes events outside the radius boundary" do
    small_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Tiny Zone",
      latitude:          -34.0,
      longitude:         -58.0,
      activation_radius: 20,  # 20m — event at ~14m inside, event at ~57m outside
      order:             1
    )
    AnalyticsEvent.create!(geo_project: @project, geo_point: small_point,
                            event_type: "radius_enter", session_id: "inside",
                            event_date: Date.today, latitude: -34.0001, longitude: -58.0001)
    AnalyticsEvent.create!(geo_project: @project, geo_point: small_point,
                            event_type: "radius_enter", session_id: "outside",
                            event_date: Date.today, latitude: -34.0004, longitude: -58.0004)

    result = call_service(small_point)
    assert_equal 2, result.total_points
    assert_equal 1, result.filtered_points
    assert_equal 1, result.hotspots.size
  end

  test "excludes events outside the polygon boundary" do
    poly_point = GeoPoint.create!(
      geo_project:        @project,
      name:               "Polygon Zone",
      latitude:           -34.0,
      longitude:          -58.0,
      activation_mode:    "polygon",
      activation_polygon: {
        "type" => "Feature",
        "geometry" => {
          "type" => "Polygon",
          "coordinates" => [[
            [-58.001, -34.001],
            [-58.001, -33.999],
            [-57.999, -33.999],
            [-57.999, -34.001],
            [-58.001, -34.001]
          ]]
        }
      },
      order: 2
    )
    AnalyticsEvent.create!(geo_project: @project, geo_point: poly_point,
                            event_type: "radius_enter", session_id: "poly-in",
                            event_date: Date.today, latitude: -34.0, longitude: -58.0)
    AnalyticsEvent.create!(geo_project: @project, geo_point: poly_point,
                            event_type: "radius_enter", session_id: "poly-out",
                            event_date: Date.today, latitude: -35.0, longitude: -59.0)

    result = call_service(poly_point)
    assert_equal 2, result.total_points
    assert_equal 1, result.filtered_points
    assert_equal 1, result.hotspots.size
  end

  # ── Live mode ─────────────────────────────────────────────────────────────────

  def make_live_visit(lat, lng, inside: true, active: true, point: @point)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     point,
      session_id:    SecureRandom.hex(8),
      lat:           lat,
      lng:           lng,
      inside_radius: inside,
      last_seen_at:  active ? Time.current : 2.minutes.ago
    )
  end

  test "live: returns empty result when no active sessions exist" do
    result = call_service(mode: :live)
    assert_equal [], result.hotspots
    assert_equal 0,  result.total_points
    assert_equal 0,  result.filtered_points
  end

  test "live: returns hotspots from active inside-boundary sessions" do
    make_live_visit(-34.0001, -58.0001)
    make_live_visit(-34.0001, -58.0001)
    result = call_service(mode: :live)
    assert_equal 1,   result.hotspots.size
    assert_equal 2,   result.hotspots.first.count
    assert_equal 1.0, result.hotspots.first.intensity
  end

  test "live: excludes sessions whose last_seen_at is outside the active window" do
    make_live_visit(-34.0001, -58.0001, active: true)
    make_live_visit(-34.0001, -58.0001, active: false)
    assert_equal 1, call_service(mode: :live).total_points
  end

  test "live: excludes sessions where inside_radius is false" do
    make_live_visit(-34.0001, -58.0001, inside: true)
    make_live_visit(-34.0001, -58.0001, inside: false)
    assert_equal 1, call_service(mode: :live).total_points
  end

  test "live: total_points equals filtered_points (pre-filtered by inside_radius)" do
    make_live_visit(-34.0001, -58.0001)
    make_live_visit(-34.0003, -58.0003)
    result = call_service(mode: :live)
    assert_equal result.total_points, result.filtered_points
  end

  test "live: date range params are ignored" do
    make_live_visit(-34.0001, -58.0001)
    result = call_service(mode: :live, from: Date.tomorrow, to: Date.tomorrow)
    assert_equal 1, result.total_points
  end

  test "live: clusters nearby sessions and normalizes intensity" do
    3.times { make_live_visit(-34.0001, -58.0001) }
    1.times { make_live_visit(-34.0002, -58.0002) }
    result = call_service(mode: :live)
    assert_equal 2,   result.hotspots.size
    assert_equal 1.0, result.hotspots.first.intensity
    assert result.hotspots.last.intensity < 1.0
  end
end
