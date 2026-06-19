require "test_helper"

# Integration tests for POST /api/public/geo_projects/:id/geo_points/:id/complete_dwell
class Api::Public::GeoPointsCompleteDwellTest < ActionDispatch::IntegrationTest
  LAT = -33.437
  LNG = -70.650

  setup do
    @org     = Organization.create!(name: "Dwell Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Dwell Project", status: "active", organization: @org)
    @point   = GeoPoint.create!(
      geo_project:        @project,
      latitude:           LAT,
      longitude:          LNG,
      lookiar_url:        "https://example.com",
      requires_dwell_time: true,
      dwell_time_seconds:  60,
    )
    @point_no_dwell = GeoPoint.create!(
      geo_project:        @project,
      latitude:           LAT,
      longitude:          LNG,
      lookiar_url:        "https://example.com",
      requires_dwell_time: false,
      dwell_time_seconds:  0,
    )
  end

  teardown do
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── started_at validation (the fixed bypass) ──────────────────────────────

  test "returns 422 when started_at is absent on a dwell-required point" do
    post_dwell(@point, lat: LAT, lng: LNG)   # no started_at
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal false,                  body["unlocked"]
    assert_equal "dwell_time_required",  body["reason"]
    assert_match /permanencia/,          body["message"]
  end

  test "returns 422 when started_at is 0 on a dwell-required point" do
    post_dwell(@point, lat: LAT, lng: LNG, started_at: 0)
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal false,                  body["unlocked"]
    assert_equal "dwell_time_required",  body["reason"]
  end

  test "returns 422 when started_at is blank string on a dwell-required point" do
    post_dwell(@point, lat: LAT, lng: LNG, started_at: "")
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal false, body["unlocked"]
    assert_equal "dwell_time_required", body["reason"]
  end

  # ── elapsed time too short ────────────────────────────────────────────────

  test "returns unlocked false when elapsed is less than dwell_time_seconds" do
    started_at = (Time.current - 30).to_i   # only 30s elapsed, need 60s
    post_dwell(@point, lat: LAT, lng: LNG, started_at: started_at)
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal false, body["unlocked"]
    assert_match /tiempo/, body["message"]
    assert_nil body["reason"]   # different error path from dwell_time_required
  end

  # ── valid completion ───────────────────────────────────────────────────────

  test "returns unlocked true when inside area and sufficient elapsed time" do
    started_at = (Time.current - 90).to_i   # 90s elapsed >= 60s required
    post_dwell(@point, lat: LAT, lng: LNG, started_at: started_at)
    assert_response :success
    assert_equal true, response.parsed_body["unlocked"]
  end

  test "exact dwell_time_seconds elapsed is sufficient" do
    started_at = (Time.current - 60).to_i   # exactly 60s
    post_dwell(@point, lat: LAT, lng: LNG, started_at: started_at)
    assert_response :success
    assert_equal true, response.parsed_body["unlocked"]
  end

  test "is idempotent: same valid call twice returns unlocked true both times" do
    started_at = (Time.current - 90).to_i
    post_dwell(@point, lat: LAT, lng: LNG, started_at: started_at)
    assert_equal true, response.parsed_body["unlocked"]
    post_dwell(@point, lat: LAT, lng: LNG, started_at: started_at)
    assert_equal true, response.parsed_body["unlocked"]
  end

  # ── GPS boundary ──────────────────────────────────────────────────────────

  test "returns unlocked false when user is outside the area boundary" do
    started_at = (Time.current - 90).to_i
    # ~5km away from the point
    post_dwell(@point, lat: -33.480, lng: -70.650, started_at: started_at)
    assert_response :unprocessable_entity
    assert_equal false, response.parsed_body["unlocked"]
    assert_match /área/, response.parsed_body["message"]
  end

  # ── Point without dwell requirement ──────────────────────────────────────

  test "returns 422 when point does not require dwell time" do
    post_dwell(@point_no_dwell, lat: LAT, lng: LNG, started_at: (Time.current - 90).to_i)
    assert_response :unprocessable_entity
    assert_equal false, response.parsed_body["unlocked"]
    assert_match /no requiere/, response.parsed_body["message"]
  end

  private

  def post_dwell(point, lat:, lng:, **extra)
    body = { latitude: lat, longitude: lng }.merge(extra)
    post "/api/public/geo_projects/#{@project.id}/geo_points/#{point.id}/complete_dwell",
         params: body.to_json,
         headers: { "Content-Type" => "application/json" }
  end
end
