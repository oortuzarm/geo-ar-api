require "test_helper"

class Api::V1::AnalyticsControllerTest < ActionDispatch::IntegrationTest
  # ── Fixtures ──────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "analytics_test_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )

    @org = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(
      title:  "Test Project",
      status: "active",
      user:   @user
    )

    @point_a = GeoPoint.create!(
      geo_project: @project,
      name:        "Point A",
      latitude:    -34.0,
      longitude:   -58.0,
      order:       0
    )

    @point_b = GeoPoint.create!(
      geo_project: @project,
      name:        "Point B",
      latitude:    -34.1,
      longitude:   -58.1,
      order:       1
    )

    # 3 radius_enter events on point_a (2 unique sessions)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point_a, event_type: "radius_enter", session_id: "sess-1", event_date: Date.today)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point_a, event_type: "radius_enter", session_id: "sess-2", event_date: Date.today)
    # 2 clicks on point_a (2 unique sessions)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point_a, event_type: "point_click",  session_id: "sess-1", event_date: Date.today)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point_a, event_type: "point_click",  session_id: "sess-2", event_date: Date.today)
    # 1 radius_enter on point_b
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point_b, event_type: "radius_enter", session_id: "sess-3", event_date: Date.today)

    # 1 active live visit on point_a
    GeoPointLiveVisit.create!(
      geo_project: @project,
      geo_point:   @point_a,
      session_id:  "live-1",
      lat:         -34.0,
      lng:         -58.0,
      inside_radius: true,
      last_seen_at:  Time.current
    )

    @credential, @secret = ApiCredential.build_with_secret(
      organization: @org,
      name:         "Test Credential",
      scopes:       ["analytics:read"]
    )
    @credential.save!
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  def auth_header(credential = @credential, secret = @secret)
    encoded = Base64.strict_encode64("#{credential.key_public}:#{secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  # ── GET /api/v1/projects/:id/analytics (summary) ──────────────────────────────

  test "summary: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}/analytics"
    assert_response :unauthorized
  end

  test "summary: returns 403 with wrong scope" do
    cred, secret = ApiCredential.build_with_secret(
      organization: @org, name: "no-analytics", scopes: ["projects:read"]
    )
    cred.save!
    get "/api/v1/projects/#{@project.id}/analytics", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "analytics:read", response.parsed_body["required"]
  end

  test "summary: returns 404 for project not in organization" do
    other_user    = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "pw", role: "user", status: "active")
    other_project = GeoProject.create!(title: "Other", status: "active", user: other_user)
    get "/api/v1/projects/#{other_project.id}/analytics", headers: auth_header
    assert_response :not_found
  end

  test "summary: returns correct structure and calculations" do
    get "/api/v1/projects/#{@project.id}/analytics", headers: auth_header
    assert_response :ok

    body = response.parsed_body
    assert body.key?("data"), "response must have 'data' key"

    summary = body["data"]["summary"]
    assert_equal 3, summary["radiusEntries"]
    assert_equal 2, summary["clicks"]
    # 2 unique clickers / 3 unique enterers (sess-1, sess-2, sess-3) = 67%
    assert_equal 67, summary["conversionPct"]

    live = body["data"]["liveVisits"]
    assert_equal 1, live["activeNow"]
    assert live.key?("lastHourDeltaPct")
    assert live.key?("peakToday")
    assert live.key?("mostActiveLocation")
    assert_equal @point_a.id, live["mostActiveLocation"]["locationId"]
  end

  test "summary: supports ?location_id filter" do
    get "/api/v1/projects/#{@project.id}/analytics?location_id=#{@point_b.id}", headers: auth_header
    assert_response :ok

    summary = response.parsed_body["data"]["summary"]
    assert_equal 1, summary["radiusEntries"]
    assert_equal 0, summary["clicks"]
  end

  test "summary: returns 404 when location_id not in project" do
    other_point = GeoPoint.create!(
      geo_project: GeoProject.create!(title: "X", status: "active", user: @user),
      name: "Foreign", latitude: 0, longitude: 0, order: 0
    )
    get "/api/v1/projects/#{@project.id}/analytics?location_id=#{other_point.id}", headers: auth_header
    assert_response :not_found
  end

  # ── GET /api/v1/projects/:id/analytics/locations ──────────────────────────────

  test "locations: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}/analytics/locations"
    assert_response :unauthorized
  end

  test "locations: returns correct per-location breakdown" do
    get "/api/v1/projects/#{@project.id}/analytics/locations", headers: auth_header
    assert_response :ok

    locs = response.parsed_body["data"]
    assert_equal 2, locs.size

    loc_a = locs.find { |l| l["locationId"] == @point_a.id }
    assert_not_nil loc_a
    assert_equal "Point A",  loc_a["locationName"]
    assert_equal 2,          loc_a["radiusEntries"]
    assert_equal 2,          loc_a["clicks"]
    assert_equal 100,        loc_a["conversionPct"]
    assert_equal 1,          loc_a["activeNow"]

    loc_b = locs.find { |l| l["locationId"] == @point_b.id }
    assert_not_nil loc_b
    assert_equal 1, loc_b["radiusEntries"]
    assert_equal 0, loc_b["activeNow"]
  end

  test "locations: includes points with zero events" do
    point_c = GeoPoint.create!(geo_project: @project, name: "Empty", latitude: 0, longitude: 0, order: 2)
    get "/api/v1/projects/#{@project.id}/analytics/locations", headers: auth_header
    assert_response :ok

    ids = response.parsed_body["data"].map { |l| l["locationId"] }
    assert_includes ids, point_c.id
  end

  # ── GET /api/v1/projects/:id/analytics/distribution ───────────────────────────

  test "distribution: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}/analytics/distribution"
    assert_response :unauthorized
  end

  test "distribution: returns byHour, byDayOfWeek, geo structure" do
    get "/api/v1/projects/#{@project.id}/analytics/distribution", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    assert data.key?("byHour"),      "missing byHour"
    assert data.key?("byDayOfWeek"), "missing byDayOfWeek"
    assert data.key?("geo"),         "missing geo"

    assert data["geo"].key?("countries")
    assert data["geo"].key?("cities")
    assert data["geo"].key?("communes")
  end

  test "distribution: hour entries have integer hour key" do
    get "/api/v1/projects/#{@project.id}/analytics/distribution", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    data["byHour"].each do |entry|
      assert entry["hour"].is_a?(Integer), "hour must be an integer"
      assert entry["count"].is_a?(Integer)
    end
  end

  test "distribution: supports ?location_id filter" do
    # Point B has only 1 radius_enter; filtering by point_a should give 4 events total
    get "/api/v1/projects/#{@project.id}/analytics/distribution?location_id=#{@point_a.id}", headers: auth_header
    assert_response :ok
    # Only point_a events counted (3 radius_enter + 2 clicks = 4 events spread across hours)
    total = response.parsed_body["data"]["byHour"].sum { |h| h["count"] }
    assert_equal 4, total
  end

  # ── GET /api/v1/projects/:id/analytics/intensity ──────────────────────────────

  test "intensity: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}/analytics/intensity"
    assert_response :unauthorized
  end

  test "intensity: returns per-location entry counts with coordinates" do
    get "/api/v1/projects/#{@project.id}/analytics/intensity", headers: auth_header
    assert_response :ok

    points = response.parsed_body["data"]
    assert_equal 2, points.size

    pt_a = points.find { |p| p["locationId"] == @point_a.id }
    assert_not_nil pt_a
    assert_equal "Point A", pt_a["locationName"]
    assert_equal(-34.0, pt_a["lat"])
    assert_equal(-58.0, pt_a["lng"])
    assert_equal 2, pt_a["entryCount"]  # only radius_enter events counted

    pt_b = points.find { |p| p["locationId"] == @point_b.id }
    assert_equal 1, pt_b["entryCount"]
  end

  test "intensity: click events are excluded from entry count" do
    # Point A has 2 radius_enter + 2 point_click; intensity must count only 2
    get "/api/v1/projects/#{@project.id}/analytics/intensity", headers: auth_header
    assert_response :ok

    pt_a = response.parsed_body["data"].find { |p| p["locationId"] == @point_a.id }
    assert_equal 2, pt_a["entryCount"]
  end
end
