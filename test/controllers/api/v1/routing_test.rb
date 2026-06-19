require "test_helper"

# Verifies cross-cutting concerns of the /api/v1 namespace:
#   - Unknown routes → 404 JSON (not HTML)
#   - Missing auth → 401 JSON
#   - Invalid credentials → 401 JSON
#   - Health endpoint remains open
class Api::V1::RoutingTest < ActionDispatch::IntegrationTest
  # ── Setup ─────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "routing_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Routing Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @credential, @secret = ApiCredential.build_with_secret(
      organization: @org,
      name:         "Routing Credential",
      scopes:       ["projects:read"]
    )
    @credential.save!
  end

  def auth_header(credential = @credential, secret = @secret)
    encoded = Base64.strict_encode64("#{credential.key_public}:#{secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  # ── 404 JSON for unknown routes ───────────────────────────────────────────────

  test "unknown GET path under /api/v1 returns 404 JSON" do
    get "/api/v1/doesnotexist"
    assert_response :not_found
    assert_equal "application/json", response.content_type.split(";").first
    assert response.parsed_body.key?("error"), "404 body must include 'error' key"
  end

  test "unknown nested path under /api/v1 returns 404 JSON" do
    get "/api/v1/projects/fake/bogus/deep"
    assert_response :not_found
    assert_equal "application/json", response.content_type.split(";").first
  end

  test "wrong HTTP method on known route returns 404 JSON" do
    # POST /presence/validate exists; GET does not
    get "/api/v1/presence/validate"
    assert_response :not_found
    assert_equal "application/json", response.content_type.split(";").first
  end

  test "unknown DELETE path under /api/v1 returns 404 JSON" do
    delete "/api/v1/doesnotexist"
    assert_response :not_found
    assert_equal "application/json", response.content_type.split(";").first
  end

  test "404 body contains error key" do
    get "/api/v1/not_a_real_endpoint"
    assert_response :not_found
    body = response.parsed_body
    assert_equal "Not found", body["error"]
  end

  # ── 401 JSON for missing / invalid credentials ────────────────────────────────

  test "missing auth returns 401 JSON" do
    get "/api/v1/projects"
    assert_response :unauthorized
    assert_equal "application/json", response.content_type.split(";").first
    assert response.parsed_body.key?("error")
  end

  test "invalid API key returns 401 JSON" do
    get "/api/v1/projects", headers: { "Authorization" => "Bearer invalid_key:invalid_secret" }
    assert_response :unauthorized
    assert_equal "application/json", response.content_type.split(";").first
    assert_equal "Invalid or missing API credentials", response.parsed_body["error"]
  end

  test "malformed Authorization header returns 401 JSON" do
    get "/api/v1/projects", headers: { "Authorization" => "Token abcdef" }
    assert_response :unauthorized
    assert_equal "application/json", response.content_type.split(";").first
  end

  test "valid credentials still authenticate correctly" do
    get "/api/v1/projects", headers: auth_header
    assert_response :ok
  end

  # ── Health endpoint remains open (no auth) ────────────────────────────────────

  test "GET /api/v1/health returns 200 JSON without auth" do
    get "/api/v1/health"
    assert_response :ok
    assert_equal "application/json", response.content_type.split(";").first
    assert_equal "ok",  response.parsed_body["status"]
    assert_equal "v1",  response.parsed_body["version"]
  end
end
