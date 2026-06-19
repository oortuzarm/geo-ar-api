require "test_helper"

class Api::V1::LocationsControllerTest < ActionDispatch::IntegrationTest
  # ── Setup ─────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "loc_test_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Loc Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(
      title:        "Test Project",
      status:       "active",
      user:         @user,
      organization: @org
    )
    @point_a = GeoPoint.create!(geo_project: @project, name: "Point A", latitude: -34.0, longitude: -58.0, order: 0)
    @point_b = GeoPoint.create!(geo_project: @project, name: "Point B", latitude: -34.1, longitude: -58.1, order: 1)

    @credential, @secret = ApiCredential.build_with_secret(
      organization: @org,
      name:         "Locations Credential",
      scopes:       ["locations:read"]
    )
    @credential.save!
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  def auth_header(credential = @credential, secret = @secret)
    encoded = Base64.strict_encode64("#{credential.key_public}:#{secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  def credential_with_scope(*scopes)
    cred, secret = ApiCredential.build_with_secret(
      organization: @org, name: "scoped-#{SecureRandom.hex(4)}", scopes: scopes
    )
    cred.save!
    [ cred, secret ]
  end

  # ── GET /api/v1/projects/:project_id/locations ────────────────────────────────

  test "index: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}/locations"
    assert_response :unauthorized
    assert_equal "Invalid or missing API credentials", response.parsed_body["error"]
  end

  test "index: returns 403 with wrong scope" do
    cred, secret = credential_with_scope("analytics:read")
    get "/api/v1/projects/#{@project.id}/locations", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body["error"]
    assert_equal "locations:read",     response.parsed_body["required"]
  end

  test "index: returns 200 with locations:read scope" do
    get "/api/v1/projects/#{@project.id}/locations", headers: auth_header
    assert_response :ok

    body = response.parsed_body
    assert body.key?("data")
    assert body.key?("meta")
    assert_equal 2, body["meta"]["count"]
  end

  test "index: returns locations ordered by order column" do
    get "/api/v1/projects/#{@project.id}/locations", headers: auth_header
    assert_response :ok

    ids = response.parsed_body["data"].map { |l| l["id"] }
    assert_equal [ @point_a.id, @point_b.id ], ids
  end

  test "index: returns 404 for project in another organization" do
    other_user = User.create!(email: "o_#{SecureRandom.hex(4)}@example.com", password: "pw", role: "user", status: "active")
    other_org  = Organization.create!(name: "Other #{SecureRandom.hex(4)}")
    other_proj = GeoProject.create!(title: "Foreign", status: "active", user: other_user, organization: other_org)

    get "/api/v1/projects/#{other_proj.id}/locations", headers: auth_header
    assert_response :not_found
  end

  # ── GET /api/v1/locations/:id ─────────────────────────────────────────────────

  test "show: returns 401 without auth" do
    get "/api/v1/locations/#{@point_a.id}"
    assert_response :unauthorized
  end

  test "show: returns 403 with wrong scope" do
    cred, secret = credential_with_scope("presence:validate")
    get "/api/v1/locations/#{@point_a.id}", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "locations:read", response.parsed_body["required"]
  end

  test "show: returns 200 with locations:read scope" do
    get "/api/v1/locations/#{@point_a.id}", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal @point_a.id, data["id"]
    assert_equal "Point A",   data["name"]
  end

  test "show: returns 404 for location in another organization" do
    other_user  = User.create!(email: "o2_#{SecureRandom.hex(4)}@example.com", password: "pw", role: "user", status: "active")
    other_org   = Organization.create!(name: "OtherOrg2 #{SecureRandom.hex(4)}")
    other_proj  = GeoProject.create!(title: "Foreign", status: "active", user: other_user, organization: other_org)
    foreign_pt  = GeoPoint.create!(geo_project: other_proj, name: "Foreign", latitude: 0, longitude: 0, order: 0)

    get "/api/v1/locations/#{foreign_pt.id}", headers: auth_header
    assert_response :not_found
  end

  test "show: returns 404 for nonexistent id" do
    get "/api/v1/locations/00000000-0000-0000-0000-000000000000", headers: auth_header
    assert_response :not_found
  end

  # ── 403 response format ───────────────────────────────────────────────────────

  test "403 body is JSON with error and required fields" do
    cred, secret = credential_with_scope("projects:read")
    get "/api/v1/locations/#{@point_a.id}", headers: auth_header(cred, secret)
    assert_response :forbidden
    body = response.parsed_body
    assert body.key?("error"),    "403 must include 'error' key"
    assert body.key?("required"), "403 must include 'required' key"
  end
end
