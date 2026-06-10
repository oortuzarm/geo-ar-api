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
    GeoPointLiveVisit.delete_all
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
    # Coords at @active_point centre → GeoEngine.inside_boundary? true
    create_live_visit(@active_point, "session-inside-active",
                      lat: INSIDE_LAT, lng: INSIDE_LNG, inside_radius: true)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body["liveVisitsInsideAreas"]
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "visit outside all active GeoPoints counts in outside" do
    # Coords far from every geo_point → GeoEngine.inside_boundary? false for all
    create_live_visit(@active_point, "session-outside",
                      lat: OUTSIDE_LAT, lng: OUTSIDE_LNG, inside_radius: false)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["liveVisitsInsideAreas"]
    assert_equal 1, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "visit inside inactive GeoPoint counts in outside" do
    # Coords at @inactive_point centre; that point is not active, so
    # GeoEngine.inside_boundary? is never called for it.
    # @active_point is ~780 km away → false → session counts as outside.
    create_live_visit(@inactive_point, "session-inside-inactive",
                      lat: @inactive_point.latitude, lng: @inactive_point.longitude,
                      inside_radius: true)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["liveVisitsInsideAreas"]
    assert_equal 1, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  test "total equals inside plus outside" do
    # 1 inside active, 1 outside all, 1 inside inactive → 1 inside, 2 outside
    create_live_visit(@active_point,   "session-1",
                      lat: INSIDE_LAT, lng: INSIDE_LNG, inside_radius: true)
    create_live_visit(@active_point,   "session-2",
                      lat: OUTSIDE_LAT, lng: OUTSIDE_LNG, inside_radius: false)
    create_live_visit(@inactive_point, "session-3",
                      lat: @inactive_point.latitude, lng: @inactive_point.longitude,
                      inside_radius: true)

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

  test "session active in two overlapping geo_points is counted once in inside" do
    second_active = GeoPoint.create!(
      geo_project:       @project,
      name:              "Second Active Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG,
      activation_radius: 50,
      order:             2,
      active:            true
    )

    # Same session_id, two rows — both at the shared centre coordinate.
    # Deduplication by last_seen_at picks one; either way the coords are inside
    # both active points, but the session should count as one person.
    create_live_visit(@active_point, "session-overlap",
                      lat: INSIDE_LAT, lng: INSIDE_LNG, inside_radius: true,
                      last_seen_at: 20.seconds.ago)
    create_live_visit(second_active, "session-overlap",
                      lat: INSIDE_LAT, lng: INSIDE_LNG, inside_radius: true,
                      last_seen_at: 10.seconds.ago)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["liveVisitsInsideAreas"],  "overlapping session counted once"
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  # ── Cross-geo_point boundary check ───────────────────────────────────────────
  #
  # Regression: heartbeat sent to geo_point A, but the session's coordinates
  # physically fall inside geo_point B's boundary.  The old implementation
  # used inside_radius (false for A) and classified this as "outside".
  # The new implementation runs GeoEngine.inside_boundary? against ALL active
  # geo_points, so the session is correctly classified as "inside".

  test "heartbeat sent to A but coords inside B is counted as inside" do
    # B has a large radius (50 km) so that INSIDE_LAT/LNG clearly falls within it.
    point_b = GeoPoint.create!(
      geo_project:       @project,
      name:              "B Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG + 0.1,   # ~9 km east of A
      activation_radius: 50_000,             # 50 km — coords are well inside
      order:             2,
      active:            true
    )

    # Heartbeat sent to A; inside_radius=false because coords are at INSIDE_LAT/LNG
    # which is ~9 km from B's centre — still within B's 50 km radius.
    # @active_point A has radius 50 m, so the same coords are outside A.
    create_live_visit(@active_point, "session-cross-boundary",
                      lat: INSIDE_LAT, lng: INSIDE_LNG, inside_radius: false)

    get "/api/geo_projects/#{@project.id}/live_visits", as: :json
    assert_response :ok
    body = response.parsed_body

    assert_equal 1, body["liveVisitsInsideAreas"],
      "session inside B's boundary must count as inside even if heartbeat was sent to A"
    assert_equal 0, body["liveVisitsOutsideAreas"]
    assert_equal 1, body["liveVisitsTotal"]
  end

  private

  def create_live_visit(point, session_id, lat:, lng:, inside_radius:, last_seen_at: 10.seconds.ago)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     point,
      session_id:    session_id,
      lat:           lat,
      lng:           lng,
      inside_radius: inside_radius,
      last_seen_at:  last_seen_at
    )
  end
end
