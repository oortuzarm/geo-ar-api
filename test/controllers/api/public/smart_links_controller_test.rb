require "test_helper"

class Api::Public::SmartLinksControllerTest < ActionDispatch::IntegrationTest
  LAT = -34.0
  LNG = -58.0

  setup do
    @user    = User.create!(email: "pub_sl_#{SecureRandom.hex(4)}@example.com",
                             password: "pw", role: "user", status: "active")
    @org     = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")
    @project = GeoProject.create!(title: "Test", status: "active", user: @user, organization: @org)
    @point   = GeoPoint.create!(
      geo_project:       @project,
      latitude:          LAT,
      longitude:         LNG,
      activation_radius: 100,
      lookiar_url:       "https://example.com/dest"
    )
    @smart_link = SmartLink.create!(
      user:            @user,
      organization:    @org,
      project:         @project,
      name:            "Test Link",
      slug:            "test-link-#{SecureRandom.hex(4)}",
      destination_url: "https://example.com/destination",
      scope_type:      "project",
      status:          "active"
    )
  end

  teardown do
    AnalyticsEvent.delete_all
    GeoPointLiveVisit.delete_all
    SmartLinkGeoPoint.delete_all
    SmartLink.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Membership.where(organization: @org).delete_all
    Organization.where(id: @org.id).destroy_all
    User.where(email: @user.email).destroy_all
  end

  # ── GET /api/public/smart_links/:organization_slug/:slug ───────────────────

  test "show: returns name, slug, organizationSlug, status" do
    get show_url
    assert_response :ok
    body = response.parsed_body
    assert_equal @smart_link.name, body["name"]
    assert_equal @smart_link.slug, body["slug"]
    assert_equal @org.slug,        body["organizationSlug"]
    assert_equal "active",         body["status"]
  end

  test "show: returns scopeType and geoPointIds" do
    get show_url
    assert_response :ok
    body = response.parsed_body
    assert_equal "project", body["scopeType"]
    assert_equal [],        body["geoPointIds"]
  end

  test "show: returns geoPointIds with exact selected point when scope_type is geo_points" do
    link = SmartLink.create!(
      user:            @user,
      organization:    @org,
      project:         @project,
      name:            "Scoped Link",
      slug:            "scoped-link-#{SecureRandom.hex(4)}",
      destination_url: "https://example.com/dest",
      scope_type:      "geo_points",
      status:          "active"
    )
    SmartLinkGeoPoint.create!(smart_link: link, geo_point: @point)

    get "/api/public/smart_links/#{@org.slug}/#{link.slug}"
    assert_response :ok
    body = response.parsed_body
    assert_equal "geo_points",  body["scopeType"]
    assert_equal [ @point.id ], body["geoPointIds"]
  end

  test "show: records smart_link_opened event with org context" do
    assert_difference "AnalyticsEvent.count", 1 do
      get show_url
    end
    event = AnalyticsEvent.last
    assert_equal "smart_link_opened", event.event_type
    assert_equal "smart_link",        event.source
    assert_equal @smart_link.id,      event.context_metadata["smart_link_id"]
    assert_equal @org.id,             event.context_metadata["organization_id"]
    assert_equal @org.slug,           event.context_metadata["organization_slug"]
  end

  test "show: returns 404 for unknown organization slug" do
    get "/api/public/smart_links/no-such-org/some-slug"
    assert_response :not_found
  end

  test "show: returns 404 for unknown smart link slug" do
    get "/api/public/smart_links/#{@org.slug}/no-such-link"
    assert_response :not_found
  end

  test "show: returns 404 for paused link" do
    @smart_link.update_column(:status, "paused")
    get show_url
    assert_response :not_found
  end

  # ── POST /api/public/smart_links/:organization_slug/:slug/validate ─────────

  test "validate: returns allowed=true when inside boundary" do
    post_validate
    assert_response :ok
    body = response.parsed_body
    assert body["allowed"]
    assert_equal "https://example.com/destination", body["destinationUrl"]
    assert_equal @point.id, body["matchedGeoPointId"]
    assert_nil body["reason"]
  end

  test "validate: response includes smartLink with org context" do
    post_validate
    smart = response.parsed_body["smartLink"]
    assert_equal @smart_link.name, smart["name"]
    assert_equal @smart_link.slug, smart["slug"]
    assert_equal @org.slug,        smart["organizationSlug"]
  end

  test "validate: returns allowed=false when outside boundary" do
    post_validate(lat: LAT + 2.0, lng: LNG + 2.0)
    assert_response :ok
    body = response.parsed_body
    refute body["allowed"]
    assert_equal "outside_boundary", body["reason"]
    assert body["message"].present?
  end

  test "validate: records analytics events on success" do
    post_validate
    assert AnalyticsEvent.exists?(event_type: "smart_link_validation_passed", source: "smart_link")
    refute AnalyticsEvent.exists?(event_type: "smart_link_redirected",         source: "smart_link")
  end

  test "validate: records failure event on denial" do
    post_validate(lat: LAT + 2.0, lng: LNG + 2.0)
    assert AnalyticsEvent.exists?(event_type: "smart_link_validation_failed",
                                  failure_reason: "outside_boundary", source: "smart_link")
  end

  test "validate: creates live_visit on success" do
    assert_difference "GeoPointLiveVisit.count", 1 do
      post_validate
    end
  end

  test "validate: returns 422 for missing coordinates" do
    post "/api/public/smart_links/#{@org.slug}/#{@smart_link.slug}/validate",
         params: { session_id: "a1b2c3d4-e5f6-4a7b-89cd-ef0123456789" }, as: :json
    assert_response :unprocessable_entity
  end

  test "validate: returns 422 for missing session_id" do
    post "/api/public/smart_links/#{@org.slug}/#{@smart_link.slug}/validate",
         params: { latitude: LAT, longitude: LNG }, as: :json
    assert_response :unprocessable_entity
  end

  test "validate: returns 404 for unknown org slug" do
    post "/api/public/smart_links/no-such-org/#{@smart_link.slug}/validate",
         params: { latitude: LAT, longitude: LNG, session_id: "abc-123" }, as: :json
    assert_response :not_found
  end

  test "validate: returns unprocessable_entity for inactive link" do
    @smart_link.update_column(:status, "paused")
    post_validate
    assert_response :unprocessable_entity
    refute response.parsed_body["allowed"]
  end

  private

  def show_url
    "/api/public/smart_links/#{@org.slug}/#{@smart_link.slug}"
  end

  def post_validate(lat: LAT, lng: LNG)
    post "/api/public/smart_links/#{@org.slug}/#{@smart_link.slug}/validate",
         params: {
           latitude:   lat,
           longitude:  lng,
           session_id: "a1b2c3d4-e5f6-4a7b-89cd-ef0123456789"
         }, as: :json
  end
end
