require "test_helper"

# Tests that from/to date params are correctly applied across all Analytics endpoints.
# Covers both the Studio surface (/api/geo_projects/:id/...) and the API v1 surface
# (/api/v1/projects/:id/analytics/...).
class DateFilterAnalyticsTest < ActionDispatch::IntegrationTest
  # ── Setup ──────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "datefilter_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "DateFilter Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(title: "Filter Project", status: "active", user: @user, organization: @org)

    @point = GeoPoint.create!(
      geo_project: @project, name: "Point", latitude: -34.0, longitude: -58.0, order: 0
    )

    # Events spread across three different dates
    @old_date    = 60.days.ago.to_date
    @mid_date    = 30.days.ago.to_date
    @recent_date = Date.today

    # 2 radius_enter on the old date
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "radius_enter", session_id: "old-1", event_date: @old_date)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "radius_enter", session_id: "old-2", event_date: @old_date)
    # 1 click on the mid date
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "point_click",  session_id: "mid-1", event_date: @mid_date)
    # 3 radius_enter on the recent date
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "radius_enter", session_id: "rec-1", event_date: @recent_date)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "radius_enter", session_id: "rec-2", event_date: @recent_date)
    AnalyticsEvent.create!(geo_project: @project, geo_point: @point, event_type: "radius_enter", session_id: "rec-3", event_date: @recent_date)

    # Log in for Studio endpoints
    post "/api/auth/login", params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok

    # Build API v1 credential for v1 endpoints
    @cred, @secret = ApiCredential.build_with_secret(
      organization: @org, name: "Test Cred", scopes: ["analytics:read"]
    )
    @cred.save!
  end

  def v1_headers
    encoded = Base64.strict_encode64("#{@cred.key_public}:#{@secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  # ── Studio: GET /api/geo_projects/:id/analytics ───────────────────────────────

  test "studio analytics: no filter returns all 6 events" do
    get "/api/geo_projects/#{@project.id}/analytics"
    assert_response :ok
    body = response.parsed_body
    assert_equal 5, body["radiusEntries"]   # 2 old + 3 recent
    assert_equal 1, body["clicks"]
  end

  test "studio analytics: from filter excludes old events" do
    get "/api/geo_projects/#{@project.id}/analytics?from=#{@mid_date}"
    assert_response :ok
    body = response.parsed_body
    # mid_date has 1 click; recent_date has 3 radius_enter → total 3 radius_enter, 1 click
    assert_equal 3, body["radiusEntries"]
    assert_equal 1, body["clicks"]
  end

  test "studio analytics: to filter excludes recent events" do
    get "/api/geo_projects/#{@project.id}/analytics?to=#{@mid_date}"
    assert_response :ok
    body = response.parsed_body
    # old_date: 2 radius_enter; mid_date: 1 click
    assert_equal 2, body["radiusEntries"]
    assert_equal 1, body["clicks"]
  end

  test "studio analytics: from+to range returns only events in window" do
    get "/api/geo_projects/#{@project.id}/analytics?from=#{@mid_date}&to=#{@mid_date}"
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["radiusEntries"]
    assert_equal 1, body["clicks"]
  end

  test "studio analytics: invalid from is silently ignored" do
    get "/api/geo_projects/#{@project.id}/analytics?from=not-a-date"
    assert_response :ok
    body = response.parsed_body
    assert_equal 5, body["radiusEntries"]   # full count — filter skipped
  end

  test "studio analytics: from later than to returns empty" do
    get "/api/geo_projects/#{@project.id}/analytics?from=#{@recent_date}&to=#{@old_date}"
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["radiusEntries"]
    assert_equal 0, body["clicks"]
  end

  # ── Studio: GET /api/geo_projects/:id/analytics_by_point ─────────────────────

  test "studio analytics_by_point: no filter returns all events" do
    get "/api/geo_projects/#{@project.id}/analytics_by_point"
    assert_response :ok
    pt = response.parsed_body["points"].first
    assert_equal 5, pt["radiusEntries"]
    assert_equal 1, pt["clicks"]
  end

  test "studio analytics_by_point: from filter narrows radius_entries" do
    get "/api/geo_projects/#{@project.id}/analytics_by_point?from=#{@recent_date}"
    assert_response :ok
    pt = response.parsed_body["points"].first
    assert_equal 3, pt["radiusEntries"]
    assert_equal 0, pt["clicks"]
  end

  test "studio analytics_by_point: date filter keeps point with zero matching events" do
    future = (Date.today + 1).to_s
    get "/api/geo_projects/#{@project.id}/analytics_by_point?from=#{future}"
    assert_response :ok
    pts = response.parsed_body["points"]
    # Point still appears, just with 0 counts
    assert_equal 1, pts.size
    assert_equal 0, pts.first["radiusEntries"]
  end

  # ── Studio: GET /api/geo_projects/:id/analytics_by_hour ──────────────────────

  test "studio analytics_by_hour: no filter returns data" do
    get "/api/geo_projects/#{@project.id}/analytics_by_hour"
    assert_response :ok
    total = response.parsed_body["data"].sum { |h| h["count"] }
    assert_equal 6, total
  end

  test "studio analytics_by_hour: from filter reduces total count" do
    get "/api/geo_projects/#{@project.id}/analytics_by_hour?from=#{@recent_date}"
    assert_response :ok
    total = response.parsed_body["data"].sum { |h| h["count"] }
    assert_equal 3, total   # only recent_date events
  end

  # ── Studio: GET /api/geo_projects/:id/analytics_by_day ───────────────────────

  test "studio analytics_by_day: no filter returns all event counts" do
    get "/api/geo_projects/#{@project.id}/analytics_by_day"
    assert_response :ok
    total = response.parsed_body["data"].sum { |h| h["count"] }
    assert_equal 6, total
  end

  test "studio analytics_by_day: to filter reduces total count" do
    get "/api/geo_projects/#{@project.id}/analytics_by_day?to=#{@old_date}"
    assert_response :ok
    total = response.parsed_body["data"].sum { |h| h["count"] }
    assert_equal 2, total   # only old_date events (2 radius_enter)
  end

  # ── API v1: GET /api/v1/projects/:id/analytics ───────────────────────────────

  test "v1 analytics summary: from filter narrows radiusEntries" do
    get "/api/v1/projects/#{@project.id}/analytics?from=#{@recent_date}", headers: v1_headers
    assert_response :ok
    assert_equal 3, response.parsed_body.dig("data", "summary", "radiusEntries")
  end

  # ── API v1: GET /api/v1/projects/:id/analytics/locations ─────────────────────

  test "v1 analytics locations: from filter narrows per-location counts" do
    get "/api/v1/projects/#{@project.id}/analytics/locations?from=#{@recent_date}", headers: v1_headers
    assert_response :ok
    loc = response.parsed_body["data"].first
    assert_equal 3, loc["radiusEntries"]
    assert_equal 0, loc["clicks"]
  end

  test "v1 analytics locations: date filter keeps location with zero events" do
    future = (Date.today + 1).to_s
    get "/api/v1/projects/#{@project.id}/analytics/locations?from=#{future}", headers: v1_headers
    assert_response :ok
    locs = response.parsed_body["data"]
    assert_equal 1, locs.size
    assert_equal 0, locs.first["radiusEntries"]
  end
end
