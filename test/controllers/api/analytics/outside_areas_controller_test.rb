require "test_helper"

class Api::Analytics::OutsideAreasControllerTest < ActionDispatch::IntegrationTest
  # ── Setup ─────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "outside_studio_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "OutsideStudio Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(title: "Outside Project", status: "active",
                                   user: @user, organization: @org)

    @active_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Active Zone",
      latitude:          -34.0,
      longitude:         -58.0,
      activation_radius: 50,
      order:             0,
      active:            true
    )

    post "/api/auth/login", params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok
  end

  # ── Authentication ────────────────────────────────────────────────────────────

  test "returns 401 without session" do
    delete "/api/auth/logout", as: :json
    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :unauthorized
  end

  # ── Parameter validation ──────────────────────────────────────────────────────

  test "returns 422 when project_id is missing" do
    get "/api/analytics/outside_areas"
    assert_response :unprocessable_entity
    assert_equal "project_id is required", response.parsed_body["error"]
  end

  test "returns 404 for unknown project_id" do
    get "/api/analytics/outside_areas?project_id=00000000-0000-0000-0000-000000000000"
    assert_response :not_found
  end

  test "returns 403 for project belonging to another organization" do
    other_user = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                               password: "pw", role: "user", status: "active")
    other_org  = Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
    other_proj = GeoProject.create!(title: "Foreign", status: "active",
                                     user: other_user, organization: other_org)
    get "/api/analytics/outside_areas?project_id=#{other_proj.id}"
    assert_response :forbidden
  end

  # ── Response structure ────────────────────────────────────────────────────────

  test "returns correct top-level structure" do
    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok

    data = response.parsed_body["data"]
    assert data.key?("mode"),     "missing mode"
    assert data.key?("hotspots"), "missing hotspots"
    assert data.key?("meta"),     "missing meta"
    assert data["meta"].key?("totalPoints")
    assert data["meta"].key?("outsidePoints")
    assert data["meta"].key?("activeGeoPointsCount")
  end

  test "defaults to historical mode" do
    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok
    assert_equal "historical", response.parsed_body["data"]["mode"]
  end

  test "accepts live mode" do
    get "/api/analytics/outside_areas?project_id=#{@project.id}&mode=live"
    assert_response :ok
    assert_equal "live", response.parsed_body["data"]["mode"]
  end

  # ── Business rule: active GeoPoints exclude GPS events ───────────────────────

  test "excludes GPS events inside active GeoPoints" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "inside-active",
      event_date: Date.today, latitude: -34.0, longitude: -58.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok

    assert_equal 0, response.parsed_body["data"]["meta"]["outsidePoints"],
      "event inside active GeoPoint must be excluded"
  end

  test "includes GPS events outside all active GeoPoints" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "outside-all",
      event_date: Date.today, latitude: -35.0, longitude: -59.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal 1, data["meta"]["outsidePoints"]
    assert_equal 1, data["hotspots"].size

    hotspot = data["hotspots"].first
    %w[lat lng count intensity radiusMeters].each do |field|
      assert hotspot.key?(field), "hotspot missing field: #{field}"
    end
  end

  test "inactive GeoPoints do not cause exclusion" do
    @active_point.update!(active: false)

    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "inside-inactive",
      event_date: Date.today, latitude: -34.0, longitude: -58.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok

    assert_equal 1, response.parsed_body["data"]["meta"]["outsidePoints"],
      "event inside inactive GeoPoint must be included"
  end

  # ── Date range filtering ──────────────────────────────────────────────────────

  test "filters by start_date" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "old",
      event_date: Date.new(2025, 1, 1), latitude: -35.0, longitude: -59.0
    )
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "recent",
      event_date: Date.today, latitude: -35.0, longitude: -59.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}&start_date=#{Date.today}"
    assert_response :ok
    assert_equal 1, response.parsed_body["data"]["meta"]["totalPoints"]
  end

  test "filters by end_date" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "old2",
      event_date: Date.new(2025, 1, 1), latitude: -35.0, longitude: -59.0
    )
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "recent2",
      event_date: Date.today, latitude: -35.0, longitude: -59.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}&end_date=2025-12-31"
    assert_response :ok
    assert_equal 1, response.parsed_body["data"]["meta"]["totalPoints"]
  end

  test "ignores malformed date params" do
    AnalyticsEvent.create!(
      geo_project: @project, geo_point: @active_point,
      event_type: "radius_enter", session_id: "any",
      event_date: Date.today, latitude: -35.0, longitude: -59.0
    )

    get "/api/analytics/outside_areas?project_id=#{@project.id}&start_date=not-a-date"
    assert_response :ok
    assert_equal 1, response.parsed_body["data"]["meta"]["totalPoints"]
  end

  # ── Empty state ───────────────────────────────────────────────────────────────

  test "returns empty hotspots when project has no GPS events" do
    get "/api/analytics/outside_areas?project_id=#{@project.id}"
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal [],            data["hotspots"]
    assert_equal 0,             data["meta"]["totalPoints"]
    assert_equal 0,             data["meta"]["outsidePoints"]
    assert_equal 1,             data["meta"]["activeGeoPointsCount"]
  end
end
