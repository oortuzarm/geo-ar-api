require "test_helper"

class Api::V1::ProjectsControllerTest < ActionDispatch::IntegrationTest
  # ── Setup ─────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "proj_test_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Proj Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(
      title:        "Test Project",
      status:       "active",
      user:         @user,
      organization: @org
    )
    GeoPoint.create!(geo_project: @project, name: "Point A", latitude: -34.0, longitude: -58.0, order: 0)
    GeoPoint.create!(geo_project: @project, name: "Point B", latitude: -34.1, longitude: -58.1, order: 1)

    @credential, @secret = ApiCredential.build_with_secret(
      organization: @org,
      name:         "Projects Credential",
      scopes:       ["projects:read"]
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

  # ── GET /api/v1/projects ──────────────────────────────────────────────────────

  test "index: returns 401 without auth" do
    get "/api/v1/projects"
    assert_response :unauthorized
    assert_equal "Invalid or missing API credentials", response.parsed_body["error"]
  end

  test "index: returns 403 with wrong scope" do
    cred, secret = credential_with_scope("analytics:read")
    get "/api/v1/projects", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body["error"]
    assert_equal "projects:read",      response.parsed_body["required"]
  end

  test "index: returns 200 with projects:read scope" do
    get "/api/v1/projects", headers: auth_header
    assert_response :ok

    body = response.parsed_body
    assert body.key?("data")
    assert body.key?("meta")
    assert_equal 1, body["meta"]["count"]
  end

  test "index: only returns projects belonging to the credential's organization" do
    other_user = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "pw", role: "user", status: "active")
    other_org  = Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
    GeoProject.create!(title: "Foreign", status: "active", user: other_user, organization: other_org)

    get "/api/v1/projects", headers: auth_header
    assert_response :ok
    assert_equal 1, response.parsed_body["meta"]["count"]
  end

  test "index: response includes locationCount for each project" do
    get "/api/v1/projects", headers: auth_header
    assert_response :ok

    project = response.parsed_body["data"].first
    assert project.key?("locationCount"), "project must include locationCount field"
    assert_equal 2, project["locationCount"]
  end

  # ── GET /api/v1/projects/:id ──────────────────────────────────────────────────

  test "show: returns 401 without auth" do
    get "/api/v1/projects/#{@project.id}"
    assert_response :unauthorized
  end

  test "show: returns 403 with wrong scope" do
    cred, secret = credential_with_scope("presence:validate")
    get "/api/v1/projects/#{@project.id}", headers: auth_header(cred, secret)
    assert_response :forbidden
    assert_equal "projects:read", response.parsed_body["required"]
  end

  test "show: returns 200 with projects:read scope" do
    get "/api/v1/projects/#{@project.id}", headers: auth_header
    assert_response :ok

    data = response.parsed_body["data"]
    assert_equal @project.id,    data["id"]
    assert_equal "Test Project", data["title"]
    assert data.key?("locationCount")
  end

  test "show: returns 404 for project in another organization" do
    other_user = User.create!(email: "o2_#{SecureRandom.hex(4)}@example.com", password: "pw", role: "user", status: "active")
    other_org  = Organization.create!(name: "Other Org2 #{SecureRandom.hex(4)}")
    other_proj = GeoProject.create!(title: "Foreign", status: "active", user: other_user, organization: other_org)

    get "/api/v1/projects/#{other_proj.id}", headers: auth_header
    assert_response :not_found
  end

  test "show: returns 404 for nonexistent id" do
    get "/api/v1/projects/00000000-0000-0000-0000-000000000000", headers: auth_header
    assert_response :not_found
  end

  # ── 403 response format ───────────────────────────────────────────────────────

  test "403 body is JSON with error and required fields" do
    cred, secret = credential_with_scope("analytics:read")
    get "/api/v1/projects", headers: auth_header(cred, secret)
    assert_response :forbidden
    body = response.parsed_body
    assert body.key?("error"),    "403 must include 'error' key"
    assert body.key?("required"), "403 must include 'required' key"
  end
end
