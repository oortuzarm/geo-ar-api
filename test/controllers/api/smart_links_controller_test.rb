require "test_helper"

class Api::SmartLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user    = User.create!(email: "sl_ctrl_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", role: "user", status: "active")
    @org     = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")
    @project = GeoProject.create!(title: "Test", status: "active", user: @user, organization: @org)
    @point   = GeoPoint.create!(geo_project: @project, latitude: -33.437, longitude: -70.650)

    post "/api/auth/login",
         params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok
  end

  teardown do
    SmartLinkGeoPoint.delete_all
    SmartLink.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Membership.where(organization: @org).delete_all
    Organization.where(id: @org.id).destroy_all
    User.where(email: @user.email).destroy_all
  end

  # ── Authentication ─────────────────────────────────────────────────────────

  test "index: returns 401 when not logged in" do
    delete "/api/auth/logout"
    get "/api/smart_links"
    assert_response :unauthorized
  end

  # ── GET /api/smart_links ───────────────────────────────────────────────────

  test "index: returns empty array when no links" do
    get "/api/smart_links"
    assert_response :ok
    assert_equal [], response.parsed_body
  end

  test "index: returns organization's non-archived links" do
    create_link(slug: "link-a", status: "active")
    create_link(slug: "link-b", status: "paused")
    create_link(slug: "link-c", status: "archived")
    get "/api/smart_links"
    assert_response :ok
    assert_equal 2, response.parsed_body.size
  end

  test "index: does not return other organization's links" do
    other_org  = Organization.create!(name: "Other #{SecureRandom.hex(4)}")
    other_user = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                               password: "pw", role: "user", status: "active")
    Membership.create!(user: other_user, organization: other_org, role: "owner")
    SmartLink.create!(user: other_user, organization: other_org, project: @project,
                      name: "Other", destination_url: "https://x.com",
                      scope_type: "project", status: "active")
    get "/api/smart_links"
    assert_response :ok
    assert_equal 0, response.parsed_body.size
    SmartLink.where(organization: other_org).delete_all
    Membership.where(organization: other_org).delete_all
    other_org.destroy
    User.where(email: other_user.email).destroy_all
  end

  # ── GET /api/smart_links/:id ───────────────────────────────────────────────

  test "show: returns link by id including organizationSlug and publicUrl" do
    link = create_link
    get "/api/smart_links/#{link.id}"
    assert_response :ok
    body = response.parsed_body
    assert_equal link.slug,  body["slug"]
    assert_equal @org.slug,  body["organizationSlug"]
    assert_equal "https://go.ubyca.com/#{@org.slug}/#{link.slug}", body["publicUrl"]
  end

  test "show: returns 404 for another organization's link" do
    other_org  = Organization.create!(name: "Other #{SecureRandom.hex(4)}")
    other_user = User.create!(email: "other2_#{SecureRandom.hex(4)}@example.com",
                               password: "pw", role: "user", status: "active")
    other_link = SmartLink.create!(user: other_user, organization: other_org, project: @project,
                                    name: "Other", destination_url: "https://x.com",
                                    scope_type: "project", status: "active")
    get "/api/smart_links/#{other_link.id}"
    assert_response :not_found
    other_link.destroy
    other_org.destroy
    User.where(email: other_user.email).destroy_all
  end

  # ── POST /api/smart_links ──────────────────────────────────────────────────

  test "create: creates a smart link assigned to current organization" do
    assert_difference "SmartLink.count", 1 do
      post "/api/smart_links",
           params: {
             name:            "My Link",
             projectId:       @project.id,
             scopeType:       "project",
             destinationType: "external_url",
             destinationUrl:  "https://example.com"
           }, as: :json
    end
    assert_response :created
    body = response.parsed_body
    assert_equal @org.id,   SmartLink.last.organization_id
    assert_equal @org.slug, body["organizationSlug"]
    assert body["publicUrl"].include?(@org.slug)
  end

  test "create: generates slug from name automatically" do
    post "/api/smart_links",
         params: { name: "VIP Festival 2026", projectId: @project.id,
                   scopeType: "project", destinationType: "external_url",
                   destinationUrl: "https://example.com" }, as: :json
    assert_response :created
    assert_equal "vip-festival-2026", response.parsed_body["slug"]
  end

  test "create: accepts custom slug" do
    post "/api/smart_links",
         params: { name: "Nombre", slug: "mi-slug-custom", projectId: @project.id,
                   scopeType: "project", destinationType: "external_url",
                   destinationUrl: "https://example.com" }, as: :json
    assert_response :created
    assert_equal "mi-slug-custom", response.parsed_body["slug"]
  end

  test "create: returns 422 for missing destination_url" do
    post "/api/smart_links",
         params: { name: "X", projectId: @project.id, scopeType: "project",
                   destinationType: "external_url" }, as: :json
    assert_response :unprocessable_entity
  end

  test "create: returns 404 for project not accessible to user" do
    other_org     = Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
    other_project = GeoProject.create!(title: "Other", status: "active", organization: other_org)
    post "/api/smart_links",
         params: { name: "X", projectId: other_project.id, scopeType: "project",
                   destinationType: "external_url", destinationUrl: "https://x.com" }, as: :json
    assert_response :not_found
    other_project.destroy
  end

  test "create: creates geo_points scope with associated points" do
    post "/api/smart_links",
         params: {
           name:            "Point Link",
           projectId:       @project.id,
           scopeType:       "geo_points",
           destinationType: "external_url",
           destinationUrl:  "https://example.com",
           geoPointIds:     [@point.id]
         }, as: :json
    assert_response :created
    assert_equal [@point.id], response.parsed_body["geoPointIds"]
  end

  test "create: returns 422 for geo_points scope without point ids" do
    post "/api/smart_links",
         params: { name: "X", projectId: @project.id, scopeType: "geo_points",
                   destinationType: "external_url", destinationUrl: "https://x.com",
                   geoPointIds: [] }, as: :json
    assert_response :unprocessable_entity
  end

  # ── PATCH /api/smart_links/:id ─────────────────────────────────────────────

  test "update: updates name and destination_url" do
    link = create_link
    patch "/api/smart_links/#{link.id}",
          params: { name: "Updated Name", destinationUrl: "https://updated.com" }, as: :json
    assert_response :ok
    assert_equal "Updated Name",          response.parsed_body["name"]
    assert_equal "https://updated.com",   response.parsed_body["destinationUrl"]
  end

  test "update: syncs geo_point_ids when provided" do
    link = create_link(scope_type: "geo_points", geo_point_ids: [@point.id])
    new_point = GeoPoint.create!(geo_project: @project, latitude: -33.5, longitude: -70.7)
    patch "/api/smart_links/#{link.id}",
          params: { geoPointIds: [new_point.id] }, as: :json
    assert_response :ok
    assert_equal [new_point.id], response.parsed_body["geoPointIds"]
  end

  # ── DELETE /api/smart_links/:id ────────────────────────────────────────────

  test "destroy: soft-deletes (sets status to archived)" do
    link = create_link
    delete "/api/smart_links/#{link.id}"
    assert_response :no_content
    assert_equal "archived", link.reload.status
  end

  test "destroy: archived link no longer appears in index" do
    link = create_link
    delete "/api/smart_links/#{link.id}"
    get "/api/smart_links"
    assert_equal 0, response.parsed_body.size
  end

  private

  def create_link(slug: "test-link-#{SecureRandom.hex(4)}", status: "active",
                  scope_type: "project", geo_point_ids: [])
    link = SmartLink.new(
      user:             @user,
      organization:     @org,
      project:          @project,
      name:             "Test Link",
      slug:             slug,
      scope_type:       scope_type,
      destination_type: "external_url",
      destination_url:  "https://example.com",
      status:           status
    )
    geo_point_ids.each { |id| link.smart_link_geo_points.build(geo_point_id: id) }
    link.save!
    link
  end
end
