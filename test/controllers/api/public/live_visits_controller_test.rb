require "test_helper"

class Api::Public::LiveVisitsControllerTest < ActionDispatch::IntegrationTest
  LAT = -34.0
  LNG = -58.0
  SESSION = "a1b2c3d4-e5f6-4a7b-89cd-ef0123456789"

  setup do
    @org     = Organization.create!(name: "LV Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Test", status: "active", organization: @org)
    @point   = GeoPoint.create!(
      geo_project:       @project,
      latitude:          LAT,
      longitude:         LNG,
      activation_radius: 100
    )
  end

  teardown do
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── Basic response fields ──────────────────────────────────────────────────

  test "returns insideRadius, distanceMeters, radiusMeters and active_now" do
    post_heartbeat
    assert_response :success
    body = response.parsed_body
    assert body.key?("insideRadius"),   "missing insideRadius"
    assert body.key?("distanceMeters"), "missing distanceMeters"
    assert body.key?("radiusMeters"),   "missing radiusMeters"
    assert body.key?("active_now"),     "missing active_now"
  end

  test "active_now reflects the current user when inside radius" do
    post_heartbeat
    assert_equal 1, response.parsed_body["active_now"]
  end

  test "active_now is 0 when user is outside radius" do
    post_heartbeat(lat: LAT + 1.0, lng: LNG + 1.0)  # ~140km away
    assert_equal 0, response.parsed_body["active_now"]
  end

  test "active_now counts all active inside_radius visits" do
    [*1..3].each { |i| create_live_visit("a#{i}b#{i}c#{i}d-e#{i}f#{i}-4#{i}a#{i}-8#{i}b#{i}-c#{i}d#{i}e#{i}f#{i}0#{i}2#{i}3#{i}") }
    post_heartbeat  # adds SESSION as 4th
    assert_equal 4, response.parsed_body["active_now"]
  end

  test "active_now does not count expired visits" do
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @point,
      session_id:    "b2c3d4e5-f6a7-4b8c-9def-012345678901",
      lat:           LAT,
      lng:           LNG,
      inside_radius: true,
      last_seen_at:  2.minutes.ago
    )
    post_heartbeat  # SESSION is inside, expired visit is not counted
    assert_equal 1, response.parsed_body["active_now"]
  end

  test "radiusMeters matches point activation_radius" do
    post_heartbeat
    assert_equal @point.activation_radius, response.parsed_body["radiusMeters"]
  end

  # ── Existing behavior unchanged ────────────────────────────────────────────

  test "returns 422 with missing lat" do
    post "/api/public/geo_points/#{@point.id}/live_visit",
         params: { session_id: SESSION, lng: LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 with invalid session_id" do
    post "/api/public/geo_points/#{@point.id}/live_visit",
         params: { session_id: "bad", lat: LAT, lng: LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 404 for unknown point" do
    post "/api/public/geo_points/00000000-0000-0000-0000-000000000000/live_visit",
         params: { session_id: SESSION, lat: LAT, lng: LNG }, as: :json
    assert_response :not_found
  end

  private

  def post_heartbeat(lat: LAT, lng: LNG, session_id: SESSION)
    post "/api/public/geo_points/#{@point.id}/live_visit",
         params: { session_id: session_id, lat: lat, lng: lng }, as: :json
  end

  def create_live_visit(session_id)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @point,
      session_id:    session_id,
      lat:           LAT,
      lng:           LNG,
      inside_radius: true,
      last_seen_at:  10.seconds.ago
    )
  end
end
