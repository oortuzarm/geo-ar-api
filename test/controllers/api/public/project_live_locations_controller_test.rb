require "test_helper"

class Api::Public::ProjectLiveLocationsControllerTest < ActionDispatch::IntegrationTest
  INSIDE_LAT  = -34.0
  INSIDE_LNG  = -58.0
  OUTSIDE_LAT = -24.0
  OUTSIDE_LNG = -48.0
  SESSION     = "a1b2c3d4-e5f6-4a7b-89cd-ef0123456789"

  setup do
    @org     = Organization.create!(name: "PLV Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "PLV Project", status: "active", organization: @org)
    @point   = GeoPoint.create!(
      geo_project:       @project,
      name:              "Active Zone",
      latitude:          INSIDE_LAT,
      longitude:         INSIDE_LNG,
      activation_radius: 50,
      order:             0,
      active:            true
    )
  end

  teardown do
    ProjectLiveVisit.delete_all
    AnalyticsEvent.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── insideAreas flag ──────────────────────────────────────────────────────────

  test "returns insideAreas: true when coords are inside an active GeoPoint" do
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    assert_response :ok
    assert_equal true, response.parsed_body["insideAreas"]
  end

  test "returns insideAreas: false when coords are outside all active GeoPoints" do
    post_location(lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)
    assert_response :ok
    assert_equal false, response.parsed_body["insideAreas"]
  end

  test "returns insideAreas: false when no active GeoPoints exist" do
    @point.update!(active: false)
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    assert_response :ok
    assert_equal false, response.parsed_body["insideAreas"]
  end

  # ── ProjectLiveVisit upsert ───────────────────────────────────────────────────

  test "creates a ProjectLiveVisit row on first call" do
    assert_difference "ProjectLiveVisit.count", 1 do
      post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    end
  end

  test "upserts — does not create a second row for the same session" do
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)

    assert_no_difference "ProjectLiveVisit.count" do
      post_location(lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)
    end
  end

  test "upsert updates lat/lng to the latest coordinates" do
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    post_location(lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)

    visit = ProjectLiveVisit.find_by!(geo_project: @project, session_id: SESSION)
    assert_in_delta OUTSIDE_LAT, visit.lat, 0.0001
    assert_in_delta OUTSIDE_LNG, visit.lng, 0.0001
  end

  # ── AnalyticsEvent deduplication ─────────────────────────────────────────────

  test "creates one AnalyticsEvent on first call today" do
    assert_difference "AnalyticsEvent.count", 1 do
      post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    end
  end

  test "does not create a second AnalyticsEvent for the same session and day" do
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)

    assert_no_difference "AnalyticsEvent.count" do
      post_location(lat: OUTSIDE_LAT, lng: OUTSIDE_LNG)
    end
  end

  test "AnalyticsEvent has correct fields" do
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    evt = AnalyticsEvent.find_by!(session_id: SESSION, event_type: "project_location")
    assert_equal @project.id, evt.geo_project_id
    assert_equal Date.current, evt.event_date
    assert_in_delta INSIDE_LAT, evt.latitude,  0.0001
    assert_in_delta INSIDE_LNG, evt.longitude, 0.0001
    assert_equal "public", evt.source
    assert_nil evt.geo_point_id
  end

  # ── Error cases ───────────────────────────────────────────────────────────────

  test "returns 404 when project does not exist" do
    post "/api/public/geo_projects/00000000-0000-4000-8000-000000000000/live_location",
         params: { session_id: SESSION, lat: INSIDE_LAT, lng: INSIDE_LNG }, as: :json
    assert_response :not_found
  end

  test "returns 404 when project is inactive" do
    @project.update!(status: "inactive")
    post_location(lat: INSIDE_LAT, lng: INSIDE_LNG)
    assert_response :not_found
  end

  test "returns 422 when session_id is missing" do
    post "/api/public/geo_projects/#{@project.id}/live_location",
         params: { lat: INSIDE_LAT, lng: INSIDE_LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when session_id is not a valid UUID v4" do
    post "/api/public/geo_projects/#{@project.id}/live_location",
         params: { session_id: "not-a-uuid", lat: INSIDE_LAT, lng: INSIDE_LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when lat is missing" do
    post "/api/public/geo_projects/#{@project.id}/live_location",
         params: { session_id: SESSION, lng: INSIDE_LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "returns 422 when lng is not numeric" do
    post "/api/public/geo_projects/#{@project.id}/live_location",
         params: { session_id: SESSION, lat: INSIDE_LAT, lng: "not-a-number" }, as: :json
    assert_response :unprocessable_entity
  end

  private

  def post_location(lat:, lng:, session_id: SESSION, accuracy: nil)
    params = { session_id: session_id, lat: lat, lng: lng }
    params[:accuracy] = accuracy if accuracy
    post "/api/public/geo_projects/#{@project.id}/live_location",
         params: params, as: :json
  end
end
