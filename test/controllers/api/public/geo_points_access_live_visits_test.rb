require "test_helper"

# Integration tests for the live_visits_minimum condition in
# POST /api/public/geo_projects/:id/geo_points/:id/access.
class Api::Public::GeoPointsAccessLiveVisitsTest < ActionDispatch::IntegrationTest
  LAT = -33.437
  LNG = -70.650

  setup do
    @org     = Organization.create!(name: "GPAccess Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Test Project", status: "active", organization: @org)
    @point   = GeoPoint.create!(
      geo_project:  @project,
      latitude:     LAT,
      longitude:    LNG,
      lookiar_url:  "https://example.com",
      availability: {
        "live_visits_enabled" => true,
        "live_visits_minimum" => 3
      }
    )
  end

  teardown do
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── Condition disabled passes through ──────────────────────────────────────

  test "grants access when live_visits condition is disabled" do
    @point.update_column(:availability, { "live_visits_enabled" => false })
    post_access
    assert_response :success
    assert response.parsed_body["success"]
  end

  # ── Failure: minimum not reached ──────────────────────────────────────────

  test "denies access when minimum is not reached" do
    # 1 active visit + 1 current user = 2 < 3 → denied
    create_live_visit("s1")
    post_access
    assert_response :unprocessable_entity
    refute response.parsed_body["success"]
  end

  test "denial message mentions minimum persons" do
    post_access
    assert_includes response.parsed_body["message"], "3"
  end

  # ── Success: minimum met ───────────────────────────────────────────────────

  test "grants access when current_count + current_user meets minimum" do
    # 2 active visits + 1 current user = 3 = minimum → allowed
    create_live_visit("s1")
    create_live_visit("s2")
    post_access
    assert_response :success
    assert response.parsed_body["success"]
  end

  test "grants access when there are more active visits than minimum" do
    5.times { |i| create_live_visit("s#{i}") }
    post_access
    assert_response :success
  end

  # ── Live visit upsert on success ───────────────────────────────────────────

  test "creates a live visit record on successful access" do
    create_live_visit("s1")
    create_live_visit("s2")
    assert_difference "GeoPointLiveVisit.count", 1 do
      post_access(session_id: "new-session")
    end
    visit = GeoPointLiveVisit.find_by(geo_point: @point, session_id: "new-session")
    assert_not_nil visit
    assert visit.inside_radius
    assert_in_delta LAT, visit.lat, 0.0001
    assert_in_delta LNG, visit.lng, 0.0001
  end

  test "upserts (updates) an existing session instead of creating duplicate" do
    create_live_visit("s1")
    create_live_visit("s2")
    post_access(session_id: "s1")  # s1 already exists
    assert_equal 2, GeoPointLiveVisit.where(geo_point: @point).count
  end

  test "does not create live visit when access is denied" do
    # Only 1 active visit, need 3 → denied
    create_live_visit("s1")
    assert_no_difference "GeoPointLiveVisit.count" do
      post_access(session_id: "should-not-be-created")
    end
    refute GeoPointLiveVisit.exists?(session_id: "should-not-be-created")
  end

  # ── Quota not consumed on live_visits failure ──────────────────────────────

  test "does not consume quota when live_visits check fails" do
    @point.update_column(:availability, {
      "quota_enabled"       => true,
      "quota_limit"         => 10,
      "quota_used"          => 0,
      "live_visits_enabled" => true,
      "live_visits_minimum" => 3
    })
    create_live_visit("s1")  # 1 + 1 = 2 < 3 → denied
    post_access
    @point.reload
    assert_equal 0, @point.availability["quota_used"]
  end

  # ── Expired/outside visits are not counted ─────────────────────────────────

  test "does not count expired visits" do
    create_live_visit("s1", last_seen_at: 2.minutes.ago)
    create_live_visit("s2", last_seen_at: 2.minutes.ago)
    # 0 active + 1 = 1 < 3 → denied
    post_access
    assert_response :unprocessable_entity
  end

  test "does not count outside_radius visits" do
    create_live_visit("s1", inside_radius: false)
    create_live_visit("s2", inside_radius: false)
    post_access
    assert_response :unprocessable_entity
  end

  private

  def post_access(session_id: "test-session")
    post "/api/public/geo_projects/#{@project.id}/geo_points/#{@point.id}/access",
         params: { latitude: LAT, longitude: LNG, session_id: session_id },
         as:     :json
  end

  def create_live_visit(session_id, inside_radius: true, last_seen_at: 10.seconds.ago)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @point,
      session_id:    session_id,
      lat:           LAT,
      lng:           LNG,
      inside_radius: inside_radius,
      last_seen_at:  last_seen_at
    )
  end
end
