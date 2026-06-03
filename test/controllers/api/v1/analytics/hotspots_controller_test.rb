require "test_helper"

class Api::V1::Analytics::HotspotsControllerTest < ActionDispatch::IntegrationTest
  # ── Setup ─────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "hotspots_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Hotspot Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(title: "Hotspot Project", status: "active", user: @user)

    # Default radius 50m — events at ~14m and ~43m from center, both inside boundary
    @point = GeoPoint.create!(
      geo_project: @project,
      name:        "Plaza Mayor",
      latitude:    -34.0,
      longitude:   -58.0,
      order:       0
    )

    # Cell A: 2 events at same 4-decimal grid cell (~14m from center)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "hs-s1",
                            event_date: Date.today, latitude: -34.0001, longitude: -58.0001)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "hs-s2",
                            event_date: Date.today, latitude: -34.0001, longitude: -58.0001)
    # Cell B: 1 event at a different grid cell (~43m from center)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point,
                            event_type: "radius_enter", session_id: "hs-s3",
                            event_date: Date.today, latitude: -34.0003, longitude: -58.0003)

    @credential, @secret = ApiCredential.build_with_secret(
      organization: @org,
      name:         "Hotspot Credential",
      scopes:       ["analytics:read"]
    )
    @credential.save!
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  def auth_header(credential = @credential, secret = @secret)
    encoded = Base64.strict_encode64("#{credential.key_public}:#{secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  # ── Authentication & authorization ────────────────────────────────────────────

  test "returns 401 without auth" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}"
    assert_response :unauthorized
  end

  test "returns 403 without analytics:read scope" do
    cred, secret = ApiCredential.build_with_secret(
      organization: @org, name: "no-scope", scopes: ["projects:read"]
    )
    cred.save!
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "analytics:read", response.parsed_body["required"]
  end

  # ── Parameter validation ──────────────────────────────────────────────────────

  test "returns 422 when location_id is missing" do
    get "/api/v1/analytics/hotspots", headers: auth_header
    assert_response :unprocessable_entity
    assert_equal "location_id is required", response.parsed_body["error"]
  end

  test "returns 404 for unknown location_id" do
    get "/api/v1/analytics/hotspots?location_id=00000000-0000-0000-0000-000000000000",
        headers: auth_header
    assert_response :not_found
  end

  test "returns 404 for location outside organization" do
    other_user    = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                                  password: "pw", role: "user", status: "active")
    other_project = GeoProject.create!(title: "Foreign", status: "active", user: other_user)
    foreign_point = GeoPoint.create!(geo_project: other_project, name: "Foreign",
                                      latitude: 0, longitude: 0, order: 0)

    get "/api/v1/analytics/hotspots?location_id=#{foreign_point.id}", headers: auth_header
    assert_response :not_found
  end

  # ── Response structure ────────────────────────────────────────────────────────

  test "returns correct top-level structure" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal @point.id,    data["locationId"]
    assert_equal "Plaza Mayor", data["locationName"]
    assert data["hotspots"].is_a?(Array)
    assert data.key?("meta")
    assert data["meta"].key?("totalEvents")
    assert data["meta"].key?("filteredEvents")
  end

  test "hotspot entries have required fields" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    hotspot = response.parsed_body["data"]["hotspots"].first
    assert_not_nil hotspot, "expected at least one hotspot"
    %w[lat lng count intensity radiusMeters].each do |field|
      assert hotspot.key?(field), "missing field: #{field}"
    end
  end

  # ── Intensity normalization ───────────────────────────────────────────────────

  test "intensity is normalized between 0.0 and 1.0" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    response.parsed_body["data"]["hotspots"].each do |h|
      assert h["intensity"] >= 0.0, "intensity below 0"
      assert h["intensity"] <= 1.0, "intensity above 1"
    end
  end

  test "hotspot with highest count has intensity 1.0" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    # Results are sorted by count desc — first entry is the maximum
    assert_equal 1.0, response.parsed_body["data"]["hotspots"].first["intensity"]
  end

  test "reports correct event counts in meta" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    meta = response.parsed_body["data"]["meta"]
    assert_equal 3, meta["totalEvents"]
    assert_equal 3, meta["filteredEvents"]
  end

  # ── Clustering ────────────────────────────────────────────────────────────────

  test "groups events in the same grid cell into one hotspot" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}", headers: auth_header
    assert_response :ok

    hotspots = response.parsed_body["data"]["hotspots"]
    assert_equal 2, hotspots.size, "expected 2 clusters (cell A + cell B)"

    top = hotspots.first
    assert_equal 2, top["count"]
  end

  # ── Edge cases ────────────────────────────────────────────────────────────────

  test "returns empty hotspots for a location with no events" do
    empty_point = GeoPoint.create!(
      geo_project: @project, name: "Empty", latitude: -35.0, longitude: -59.0, order: 1
    )
    get "/api/v1/analytics/hotspots?location_id=#{empty_point.id}", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal [],  data["hotspots"]
    assert_equal 0,   data["meta"]["totalEvents"]
    assert_equal 0,   data["meta"]["filteredEvents"]
  end

  test "excludes point_click events from hotspot calculation" do
    click_point = GeoPoint.create!(
      geo_project: @project, name: "Clicks Only", latitude: -36.0, longitude: -60.0, order: 2
    )
    AnalyticsEvent.create!(geo_project: @project, geo_point: click_point,
                            event_type: "point_click", session_id: "click-1",
                            event_date: Date.today, latitude: -36.0001, longitude: -60.0001)

    get "/api/v1/analytics/hotspots?location_id=#{click_point.id}", headers: auth_header
    assert_response :ok
    assert_equal 0, response.parsed_body["data"]["meta"]["totalEvents"]
  end

  # ── Date range filtering ──────────────────────────────────────────────────────

  test "filters by start_date" do
    dated_point = GeoPoint.create!(
      geo_project: @project, name: "Dated", latitude: -37.0, longitude: -61.0, order: 3
    )
    AnalyticsEvent.create!(geo_project: @project, geo_point: dated_point,
                            event_type: "radius_enter", session_id: "old",
                            event_date: Date.new(2025, 1, 1), latitude: -37.0001, longitude: -61.0001)
    AnalyticsEvent.create!(geo_project: @project, geo_point: dated_point,
                            event_type: "radius_enter", session_id: "recent",
                            event_date: Date.today, latitude: -37.0001, longitude: -61.0001)

    get "/api/v1/analytics/hotspots?location_id=#{dated_point.id}&start_date=#{Date.today}",
        headers: auth_header
    assert_response :ok
    assert_equal 1, response.parsed_body["data"]["meta"]["totalEvents"]
  end

  test "filters by end_date" do
    dated_point = GeoPoint.create!(
      geo_project: @project, name: "Dated2", latitude: -38.0, longitude: -62.0, order: 4
    )
    AnalyticsEvent.create!(geo_project: @project, geo_point: dated_point,
                            event_type: "radius_enter", session_id: "old2",
                            event_date: Date.new(2025, 1, 1), latitude: -38.0001, longitude: -62.0001)
    AnalyticsEvent.create!(geo_project: @project, geo_point: dated_point,
                            event_type: "radius_enter", session_id: "recent2",
                            event_date: Date.today, latitude: -38.0001, longitude: -62.0001)

    get "/api/v1/analytics/hotspots?location_id=#{dated_point.id}&end_date=2025-12-31",
        headers: auth_header
    assert_response :ok
    assert_equal 1, response.parsed_body["data"]["meta"]["totalEvents"]
  end

  test "ignores malformed date params gracefully" do
    get "/api/v1/analytics/hotspots?location_id=#{@point.id}&start_date=not-a-date",
        headers: auth_header
    assert_response :ok
    assert_equal 3, response.parsed_body["data"]["meta"]["totalEvents"]
  end
end
