require "test_helper"

class Api::LiveVisitsControllerTest < ActionDispatch::IntegrationTest
  # Active point centre — sessions with coords here are inside @active_point.
  INSIDE_LAT = -34.0
  INSIDE_LNG = -58.0

  # Far enough from every test geo_point that GeoEngine.inside_boundary? returns
  # false for all of them (>1 000 km away).
  OUTSIDE_LAT = -24.0
  OUTSIDE_LNG = -48.0

  setup do
    @user = User.create!(
      email:    "live_studio_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Live Studio Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(title: "Live Project", status: "active",
                                   user: @user, organization: @org)

    @active_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Active Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG,
      activation_radius: 50,
      order:             0,
      active:            true
    )

    # Inactive point placed far from INSIDE coords so it never trips the
    # GeoEngine check accidentally.
    @inactive_point = GeoPoint.create!(
      geo_project:       @project,
      name:              "Inactive Zone",
      latitude:          INSIDE_LAT + 5.0,
      longitude:         INSIDE_LNG + 5.0,
      activation_radius: 50,
      order:             1,
      active:            false
    )

    post "/api/auth/login", params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok
  end

  teardown do
    ProjectLiveVisit.delete_all
    GeoPointLiveVisit.delete_all
    AnalyticsEvent.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── Field presence ────────────────────────────────────────────────────────────

  test "returns liveVisitsInsideAreas, liveVisitsOutsideAreas, liveVisitsTotal fields" do
    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert body.key?("liveVisitsInsideAreas"),  "missing liveVisitsInsideAreas"
    assert body.key?("liveVisitsOutsideAreas"), "missing liveVisitsOutsideAreas"
    assert body.key?("liveVisitsTotal"),        "missing liveVisitsTotal"
  end

  # ── Empty state ───────────────────────────────────────────────────────────────

  test "no active visits returns 0 for all three metrics" do
    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["liveVisitsInsideAreas"]
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 0, body["liveVisitsTotal"]
  end

  # ── Business rules ────────────────────────────────────────────────────────────

  test "visit inside active GeoPoint counts in inside" do
    create_project_live_visit("session-inside-active", lat: INSIDE_LAT, lng: INSIDE_LNG)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body["liveVisitsInsideAreas"]
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "visit outside all active GeoPoints counts in outside" do
    create_project_live_visit("session-outside", lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["liveVisitsInsideAreas"]
    assert_equal 1, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "visit inside inactive GeoPoint counts in outside" do
    # @inactive_point centre is ~780 km from @active_point (50 m radius) →
    # GeoEngine.inside_boundary? returns false for all active points → outside.
    create_project_live_visit("session-inside-inactive",
                              lat: @inactive_point.latitude,
                              lng: @inactive_point.longitude)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["liveVisitsInsideAreas"]
    assert_equal 1, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "total equals inside plus outside" do
    # 1 inside active, 1 outside all, 1 inside inactive → 1 inside, 2 outside
    create_project_live_visit("session-1", lat: INSIDE_LAT, lng: INSIDE_LNG)
    create_project_live_visit("session-2", lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)
    create_project_live_visit("session-3",
                              lat: @inactive_point.latitude,
                              lng: @inactive_point.longitude)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["liveVisitsInsideAreas"]
    assert_equal 2, body["liveVisitsOutsideAreas"]
    assert_equal 3, body["liveVisitsTotal"]
    assert_equal body["liveVisitsInsideAreas"] + body["liveVisitsOutsideAreas"],
                 body["liveVisitsTotal"],
                 "total must equal inside + outside"
  end

  # ProjectLiveVisit has a unique index on (project, session), so each session
  # has exactly one row.  A session whose coords fall inside two overlapping
  # active GeoPoints must still count as one person — verified here.
  test "session inside two overlapping geo_points is counted once in inside" do
    GeoPoint.create!(
      geo_project:       @project,
      name:              "Second Active Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG,
      activation_radius: 50,
      order:             2,
      active:            true
    )

    create_project_live_visit("session-overlap", lat: INSIDE_LAT, lng: INSIDE_LNG)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["liveVisitsInsideAreas"], "overlapping session counted once"
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  # ── Cross-geo_point boundary check ───────────────────────────────────────────
  #
  # Coordinates fall inside geo_point B's boundary but outside geo_point A's
  # (A has 50 m radius, B has 50 km radius centred ~9 km away).
  # three_way_live_counts must check ALL active points — coords inside B must
  # classify as "inside" regardless of A.

  test "coords inside B but outside A are classified as inside" do
    GeoPoint.create!(
      geo_project:       @project,
      name:              "B Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG + 0.1,   # ~9 km east of A
      activation_radius: 50_000,             # 50 km — INSIDE_LAT/LNG is well inside
      order:             2,
      active:            true
    )

    # Coords at INSIDE_LAT/LNG: outside A's 50 m radius, inside B's 50 km radius.
    create_project_live_visit("session-cross-boundary",
                              lat: INSIDE_LAT, lng: INSIDE_LNG)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["liveVisitsInsideAreas"],
      "session inside B's boundary must count as inside"
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  # ── Period metrics ────────────────────────────────────────────────────────────

  test "period metrics fields are present in response" do
    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert body.key?("periodPeopleInsideAreas"),  "missing periodPeopleInsideAreas"
    assert body.key?("periodPeopleOutsideAreas"), "missing periodPeopleOutsideAreas"
    assert body.key?("periodPeopleTotal"),        "missing periodPeopleTotal"
  end

  test "period without activity returns 0 for all three period metrics" do
    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["periodPeopleInsideAreas"]
    assert_equal 0, body["periodPeopleOutsideAreas"]
    assert_equal 0, body["periodPeopleTotal"]
  end

  test "unique person inside active area counts in period inside" do
    create_analytics_event("p-inside", INSIDE_LAT, INSIDE_LNG, Date.today)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body["periodPeopleInsideAreas"]
    assert_equal 0, body["periodPeopleOutsideAreas"]
    assert_equal 1, body["periodPeopleTotal"]
  end

  test "unique person outside active areas counts in period outside" do
    create_analytics_event("p-outside", OUTSIDE_LAT, OUTSIDE_LNG, Date.today)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["periodPeopleInsideAreas"]
    assert_equal 1, body["periodPeopleOutsideAreas"]
    assert_equal 1, body["periodPeopleTotal"]
  end

  # Person A: events inside AND outside.  Person B: only outside.
  # Expected: inside=1, outside=2, total=2 (union, not sum).
  test "person present in both groups counted in each, total is union not sum" do
    create_analytics_event("p-both", INSIDE_LAT,  INSIDE_LNG,  Date.today, geo_point: @active_point)
    create_analytics_event("p-both", OUTSIDE_LAT, OUTSIDE_LNG, Date.today, geo_point: @inactive_point)
    create_analytics_event("p-only-outside", OUTSIDE_LAT, OUTSIDE_LNG, Date.today, geo_point: @inactive_point)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["periodPeopleInsideAreas"]
    assert_equal 2, body["periodPeopleOutsideAreas"]
    assert_equal 2, body["periodPeopleTotal"],
      "total must be the union — p-both counted once despite being in both groups"
  end

  test "inactive area does not count as active area for period classification" do
    # Coords at @inactive_point centre — ~780 km from @active_point (50 m radius)
    # → GeoEngine.inside_boundary? returns false for all ACTIVE points
    create_analytics_event("p-inactive-area",
                           @inactive_point.latitude, @inactive_point.longitude,
                           Date.today, geo_point: @inactive_point)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["periodPeopleInsideAreas"],
      "inactive area must not count as an active area"
    assert_equal 1, body["periodPeopleOutsideAreas"]
    assert_equal 1, body["periodPeopleTotal"]
  end

  test "date range filter includes only events within range" do
    yesterday = Date.today - 1
    today     = Date.today

    create_analytics_event("p-yesterday", INSIDE_LAT, INSIDE_LNG, yesterday)
    create_analytics_event("p-today",     INSIDE_LAT, INSIDE_LNG, today)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{yesterday}&to=#{yesterday}", as: :json
    assert_equal 1, response.parsed_body["periodPeopleInsideAreas"],
      "yesterday-only range must count only the event from yesterday"

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{today}&to=#{today}", as: :json
    assert_equal 1, response.parsed_body["periodPeopleInsideAreas"],
      "today-only range must count only the event from today"

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{yesterday}&to=#{today}", as: :json
    assert_equal 2, response.parsed_body["periodPeopleInsideAreas"],
      "full range must count both events"
  end

  # When sessions have no overlap (each in exactly one group),
  # total must equal inside + outside — consistent with the outside-areas logic.
  test "period metrics are consistent with outside areas spatial logic" do
    create_analytics_event("p-cons-inside",  INSIDE_LAT,  INSIDE_LNG,  Date.today)
    create_analytics_event("p-cons-outside", OUTSIDE_LAT, OUTSIDE_LNG, Date.today)

    get "/api/geo_projects/#{@project.id}/live_visits?from=#{Date.today}&to=#{Date.today}", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["periodPeopleInsideAreas"]
    assert_equal 1, body["periodPeopleOutsideAreas"]
    assert_equal body["periodPeopleInsideAreas"] + body["periodPeopleOutsideAreas"],
                 body["periodPeopleTotal"],
                 "when sets are disjoint, total equals sum — consistent with spatial classification"
  end

  private

  def create_analytics_event(session_id, lat, lng, date, geo_point: nil)
    AnalyticsEvent.create!(
      geo_project: @project,
      geo_point:   geo_point || @active_point,
      event_type:  "radius_enter",
      session_id:  session_id,
      event_date:  date,
      latitude:    lat,
      longitude:   lng
    )
  end

  def create_project_live_visit(session_id, lat:, lng:, last_seen_at: 10.seconds.ago)
    ProjectLiveVisit.create!(
      geo_project:  @project,
      session_id:   session_id,
      lat:          lat,
      lng:          lng,
      last_seen_at: last_seen_at
    )
  end
end
