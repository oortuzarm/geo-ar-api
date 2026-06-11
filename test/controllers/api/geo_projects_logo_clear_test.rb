require "test_helper"

# Regression tests for logo-field clearing when the frontend sends null.
#
# Covers both the update (PATCH /api/geo_projects/:id) and the sync
# (PATCH /api/geo_projects/:id/sync) code paths, plus the public endpoint.
class Api::GeoProjectsLogoClearTest < ActionDispatch::IntegrationTest
  LOGO_URL = "https://cdn.example.com/logo.png"

  setup do
    @user = User.create!(
      email:    "logo_clear_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Logo Clear Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")

    @project = GeoProject.create!(
      title:               "Logo Project",
      status:              "active",
      user:                @user,
      organization:        @org,
      project_logo_url:        LOGO_URL,
      project_logo_zoom:       1.5,
      project_logo_position_x: 10.0,
      project_logo_position_y: 20.0
    )

    post "/api/auth/login",
         params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok
  end

  teardown do
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── PATCH /api/geo_projects/:id (update path) ─────────────────────────────────

  test "update with null project_logo_url clears the column in DB" do
    patch "/api/geo_projects/#{@project.id}",
          params: { project_logo_url: nil }, as: :json
    assert_response :ok
    assert_nil @project.reload.project_logo_url
  end

  test "update with null logo fields returns null in private API response" do
    patch "/api/geo_projects/#{@project.id}",
          params: {
            project_logo_url:        nil,
            project_logo_zoom:       nil,
            project_logo_position_x: nil,
            project_logo_position_y: nil
          }, as: :json
    assert_response :ok
    body = response.parsed_body
    assert_nil body["projectLogoUrl"]
    assert_nil body["projectLogoZoom"]
    assert_nil body["projectLogoPositionX"]
    assert_nil body["projectLogoPositionY"]
  end

  test "after update with null logo, GET returns null in private response" do
    patch "/api/geo_projects/#{@project.id}",
          params: { project_logo_url: nil }, as: :json

    get "/api/geo_projects/#{@project.id}", as: :json
    assert_response :ok
    assert_nil response.parsed_body["projectLogoUrl"]
  end

  # ── PATCH /api/geo_projects/:id/sync (sync path) ─────────────────────────────

  test "sync with null project_logo_url clears the column in DB" do
    patch "/api/geo_projects/#{@project.id}/sync",
          params: { title: @project.title, project_logo_url: nil, geo_points: [] },
          as: :json
    assert_response :ok
    assert_nil @project.reload.project_logo_url
  end

  test "sync with null logo fields persists all four as NULL" do
    patch "/api/geo_projects/#{@project.id}/sync",
          params: {
            title:                   @project.title,
            project_logo_url:        nil,
            project_logo_zoom:       nil,
            project_logo_position_x: nil,
            project_logo_position_y: nil,
            geo_points:              []
          }, as: :json
    assert_response :ok
    p = @project.reload
    assert_nil p.project_logo_url
    assert_nil p.project_logo_zoom
    assert_nil p.project_logo_position_x
    assert_nil p.project_logo_position_y
  end

  # ── Public endpoint ───────────────────────────────────────────────────────────

  test "after clearing logo, public endpoint returns null projectLogoUrl" do
    @project.update_columns(
      project_logo_url:        nil,
      project_logo_zoom:       nil,
      project_logo_position_x: nil,
      project_logo_position_y: nil
    )

    get "/api/public/geo_projects/#{@project.id}", as: :json
    assert_response :ok
    body = response.parsed_body
    assert_nil body["projectLogoUrl"]
    assert_nil body["projectLogoZoom"]
    assert_nil body["projectLogoPositionX"]
    assert_nil body["projectLogoPositionY"]
  end

  # ── Non-regression: setting then re-reading ───────────────────────────────────

  test "logo fields survive a round-trip through update" do
    patch "/api/geo_projects/#{@project.id}",
          params: {
            project_logo_url:        LOGO_URL,
            project_logo_zoom:       2.0,
            project_logo_position_x: -5.5,
            project_logo_position_y: 15.25
          }, as: :json
    assert_response :ok

    get "/api/geo_projects/#{@project.id}", as: :json
    body = response.parsed_body
    assert_equal LOGO_URL, body["projectLogoUrl"]
    assert_in_delta 2.0,   body["projectLogoZoom"],       0.001
    assert_in_delta(-5.5,  body["projectLogoPositionX"],  0.001)
    assert_in_delta 15.25, body["projectLogoPositionY"],  0.001
  end
end
