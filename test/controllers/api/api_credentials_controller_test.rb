require "test_helper"

class Api::ApiCredentialsControllerTest < ActionDispatch::IntegrationTest
  # ── Setup ──────────────────────────────────────────────────────────────────────

  setup do
    @user = User.create!(
      email:    "cred_test_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    # Log in so session cookie is set for all subsequent requests.
    post "/api/auth/login",
         params: { email: @user.email, password: "password123" },
         as: :json
    assert_response :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────────

  def build_credential(name: "Test Key", scopes: ["analytics:read"], **attrs)
    cred, _secret = ApiCredential.build_with_secret(
      organization:    @org,
      name:            name,
      scopes:          scopes,
      created_by_user: @user,
      **attrs
    )
    cred.save!
    cred
  end

  # ── GET /api/api_credentials (index) ──────────────────────────────────────────

  test "index: returns 401 when not logged in" do
    delete "/api/auth/logout"
    get "/api/api_credentials"
    assert_response :unauthorized
  end

  test "index: returns 200 with empty array when no credentials" do
    get "/api/api_credentials"
    assert_response :ok
    assert_equal [], response.parsed_body
  end

  test "index: returns credentials with expected camelCase fields" do
    cred = build_credential(name: "Prod Key", scopes: ["analytics:read"])
    get "/api/api_credentials"
    assert_response :ok

    body = response.parsed_body
    assert_equal 1, body.size

    item = body.first
    assert_equal cred.id,         item["id"]
    assert_equal "Prod Key",      item["name"]
    assert_equal cred.key_public, item["key"]
    assert_equal true,            item["active"]
    assert_equal ["analytics:read"], item["scopes"]
    assert item.key?("lastUsedAt")
    assert item.key?("createdAt")
  end

  test "index: never includes secret or digest fields" do
    build_credential
    get "/api/api_credentials"
    assert_response :ok

    item = response.parsed_body.first
    refute item.key?("secret"),                  "secret must not appear in index"
    refute item.key?("keySecretDigest"),          "keySecretDigest must not appear"
    refute item.key?("previousKeySecretDigest"),  "previousKeySecretDigest must not appear"
  end

  test "index: only returns credentials from the current user's organization" do
    build_credential(name: "My Key")

    other_user = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com",
                              password: "pw123", role: "user", status: "active")
    other_org  = Organization.create!(name: "Other Org")
    Membership.create!(user: other_user, organization: other_org, role: "owner")
    ApiCredential.build_with_secret(organization: other_org, name: "Other Key",
                                    scopes: ["analytics:read"]).first.save!

    get "/api/api_credentials"
    assert_response :ok
    assert_equal 1, response.parsed_body.size
    assert_equal "My Key", response.parsed_body.first["name"]
  end

  # ── POST /api/api_credentials (create) ────────────────────────────────────────

  test "create: returns 401 when not logged in" do
    delete "/api/auth/logout"
    post "/api/api_credentials",
         params: { name: "Key", scopes: ["analytics:read"] }, as: :json
    assert_response :unauthorized
  end

  test "create: returns 201 with secret in response" do
    post "/api/api_credentials",
         params: { name: "Production", scopes: ["analytics:read"] }, as: :json
    assert_response :created

    body = response.parsed_body
    assert body.key?("id")
    assert body.key?("secret"),              "secret must be present on create"
    assert_match(/\Aubs_live_/, body["secret"])
    assert_equal "Production",               body["name"]
    assert_equal ["analytics:read"],         body["scopes"]
    assert_equal true,                       body["active"]
    assert body["key"].start_with?("ubk_live_")
  end

  test "create: persists credential scoped to the organization" do
    post "/api/api_credentials",
         params: { name: "My Key", scopes: ["presence:validate"] }, as: :json
    assert_response :created

    id   = response.parsed_body["id"]
    cred = @org.api_credentials.find(id)
    assert_equal "My Key",              cred.name
    assert_equal ["presence:validate"], cred.scopes
    assert_equal "active",              cred.status
    assert_equal @user.id,             cred.created_by_user_id
  end

  test "create: returns 422 when name is blank" do
    post "/api/api_credentials",
         params: { name: "", scopes: ["analytics:read"] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/nombre/, response.parsed_body["error"])
  end

  test "create: returns 422 when scopes is empty" do
    post "/api/api_credentials",
         params: { name: "Key", scopes: [] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/scope/, response.parsed_body["error"])
  end

  test "create: returns 422 when scopes contains invalid values" do
    post "/api/api_credentials",
         params: { name: "Key", scopes: ["invalid:scope", "fake:perm"] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/inválido/, response.parsed_body["error"])
  end

  test "create: accepts multiple valid scopes" do
    post "/api/api_credentials",
         params: { name: "Full Key", scopes: ["analytics:read", "presence:validate"] }, as: :json
    assert_response :created
    assert_equal ["analytics:read", "presence:validate"], response.parsed_body["scopes"]
  end

  # ── PATCH /api/api_credentials/:id (update) ───────────────────────────────────

  test "update: returns 401 when not logged in" do
    cred = build_credential
    delete "/api/auth/logout"
    patch "/api/api_credentials/#{cred.id}", params: { active: false }, as: :json
    assert_response :unauthorized
  end

  test "update: returns 404 for credential outside the organization" do
    other_org  = Organization.create!(name: "Other")
    other_cred, _s = ApiCredential.build_with_secret(organization: other_org,
                                                     name: "Foreign",
                                                     scopes: ["analytics:read"])
    other_cred.save!

    patch "/api/api_credentials/#{other_cred.id}", params: { active: false }, as: :json
    assert_response :not_found
  end

  test "update: active false sets status to revoked" do
    cred = build_credential
    assert_equal "active", cred.status

    patch "/api/api_credentials/#{cred.id}", params: { active: false }, as: :json
    assert_response :ok
    assert_equal false, response.parsed_body["active"]
    assert_equal "revoked", cred.reload.status
  end

  test "update: active true sets status to active" do
    cred = build_credential
    cred.update!(status: "revoked")

    patch "/api/api_credentials/#{cred.id}", params: { active: true }, as: :json
    assert_response :ok
    assert_equal true, response.parsed_body["active"]
    assert_equal "active", cred.reload.status
  end

  test "update: returns 422 when reactivating an expired credential" do
    cred = build_credential
    cred.update!(status: "revoked", expires_at: 1.day.ago)

    patch "/api/api_credentials/#{cred.id}", params: { active: true }, as: :json
    assert_response :unprocessable_entity
    assert_match(/expirada/, response.parsed_body["error"])
  end

  test "update: returns 422 when active param is missing" do
    cred = build_credential
    patch "/api/api_credentials/#{cred.id}", params: {}, as: :json
    assert_response :unprocessable_entity
  end

  test "update: response never includes secret" do
    cred = build_credential
    patch "/api/api_credentials/#{cred.id}", params: { active: false }, as: :json
    assert_response :ok
    refute response.parsed_body.key?("secret")
  end

  # ── POST /api/api_credentials/:id/regenerate_secret ───────────────────────────

  test "regenerate_secret: returns 401 when not logged in" do
    cred = build_credential
    delete "/api/auth/logout"
    post "/api/api_credentials/#{cred.id}/regenerate_secret"
    assert_response :unauthorized
  end

  test "regenerate_secret: returns 404 for credential outside the organization" do
    other_org  = Organization.create!(name: "Stranger Org")
    other_cred, _s = ApiCredential.build_with_secret(organization: other_org,
                                                     name: "Stranger Key",
                                                     scopes: ["analytics:read"])
    other_cred.save!

    post "/api/api_credentials/#{other_cred.id}/regenerate_secret"
    assert_response :not_found
  end

  test "regenerate_secret: returns id and new secret" do
    cred = build_credential
    old_digest = cred.key_secret_digest

    post "/api/api_credentials/#{cred.id}/regenerate_secret"
    assert_response :ok

    body = response.parsed_body
    assert_equal cred.id, body["id"]
    assert body.key?("secret"),           "secret must be present in regenerate response"
    assert_match(/\Aubs_live_/, body["secret"])
    refute body.key?("keySecretDigest"),  "digest must not be exposed"
  end

  test "regenerate_secret: changes the key_secret_digest" do
    cred = build_credential
    old_digest = cred.key_secret_digest

    post "/api/api_credentials/#{cred.id}/regenerate_secret"
    assert_response :ok

    assert_not_equal old_digest, cred.reload.key_secret_digest
  end

  test "regenerate_secret: moves old digest to previous_key_secret_digest with grace window" do
    cred = build_credential
    old_digest = cred.key_secret_digest

    post "/api/api_credentials/#{cred.id}/regenerate_secret"
    assert_response :ok

    cred.reload
    assert_equal old_digest,    cred.previous_key_secret_digest
    assert cred.previous_key_expires_at > Time.current
    assert cred.previous_key_expires_at <= 2.hours.from_now
  end
end
