require "test_helper"

# Regression tests for DELETE /api/geo_points/:id.
#
# Each scenario must return 204 (no 500) and leave the DB consistent.
# Previously failing cases:
#   - geo_point_collections table missing (migration pending) → PG::UndefinedTable
#   - smart_link_geo_points FK without on_delete → PG::ForeignKeyViolation
class Api::GeoPointsDestroyTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email:    "destroy_pts_#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      role:     "user",
      status:   "active"
    )
    @org = Organization.create!(name: "Destroy Org #{SecureRandom.hex(4)}")
    Membership.create!(user: @user, organization: @org, role: "owner")
    @project = GeoProject.create!(title: "Destroy Project", status: "active",
                                   user: @user, organization: @org)

    post "/api/auth/login",
         params: { email: @user.email, password: "password123" }, as: :json
    assert_response :ok
  end

  teardown do
    GeoPointCollection.delete_all
    SmartLinkGeoPoint.delete_all
    SmartLink.delete_all
    AnalyticsEvent.delete_all
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── Basic delete ──────────────────────────────────────────────────────────────

  test "deletes a point with no relations and returns 204" do
    point = create_point("Solo Point")

    delete "/api/geo_points/#{point.id}", as: :json
    assert_response :no_content
    assert_nil GeoPoint.find_by(id: point.id)
  end

  # ── Analytics events ──────────────────────────────────────────────────────────
  # analytics_events have dependent: :destroy on GeoPoint — must not raise.

  test "deletes a point with analytics events and returns 204" do
    point = create_point("Analytics Point")
    AnalyticsEvent.create!(
      geo_project: @project,
      geo_point:   point,
      event_type:  "radius_enter",
      session_id:  SecureRandom.uuid,
      event_date:  Date.today
    )

    assert_difference "AnalyticsEvent.count", -1 do
      delete "/api/geo_points/#{point.id}", as: :json
    end
    assert_response :no_content
  end

  # ── GeoPointLiveVisit ─────────────────────────────────────────────────────────

  test "deletes a point with live visits and returns 204" do
    point = create_point("Live Visit Point")
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     point,
      session_id:    SecureRandom.uuid,
      lat:           -34.0,
      lng:           -58.0,
      inside_radius: true,
      last_seen_at:  Time.current
    )

    assert_difference "GeoPointLiveVisit.count", -1 do
      delete "/api/geo_points/#{point.id}", as: :json
    end
    assert_response :no_content
  end

  # ── SmartLink reference ───────────────────────────────────────────────────────
  # smart_link_geo_points has a FK to geo_points with no on_delete.
  # GeoPoint now has has_many :smart_link_geo_points, dependent: :destroy
  # so the join row is removed before the FK check fires.

  test "deletes a point referenced by a SmartLink and returns 204" do
    point      = create_point("SmartLink Point")
    smart_link = SmartLink.create!(
      user:             @user,
      organization:     @org,
      project:          @project,
      name:             "Test SL #{SecureRandom.hex(4)}",
      scope_type:       "project",
      destination_type: "external_url",
      destination_url:  "https://example.com",
      status:           "active"
    )
    SmartLinkGeoPoint.create!(smart_link: smart_link, geo_point: point)

    assert_difference "SmartLinkGeoPoint.count", -1 do
      delete "/api/geo_points/#{point.id}", as: :json
    end
    assert_response :no_content
    assert smart_link.reload.present?, "SmartLink itself must survive"
  end

  # ── Collection prerequisite ───────────────────────────────────────────────────
  # When point A requires point B, deleting B must cascade-remove the
  # collection row (DB on_delete: :cascade on required_geo_point_id FK).

  test "deletes a point used as a prerequisite in another point's collection" do
    main_point     = create_point("Main Point")
    required_point = create_point("Required Point")
    GeoPointCollection.create!(geo_point: main_point, required_geo_point: required_point)

    assert_difference "GeoPointCollection.count", -1 do
      delete "/api/geo_points/#{required_point.id}", as: :json
    end
    assert_response :no_content
    assert main_point.reload.present?, "main_point must survive"
    assert_equal 0, main_point.geo_point_collections.count
  end

  # ── Collection owner ─────────────────────────────────────────────────────────
  # Deleting the main point must also remove its collection rows (dependent: :destroy).

  test "deletes a point that owns collection requirements" do
    main_point     = create_point("Main with Reqs")
    required_point = create_point("Required")
    GeoPointCollection.create!(geo_point: main_point, required_geo_point: required_point)

    assert_difference "GeoPointCollection.count", -1 do
      delete "/api/geo_points/#{main_point.id}", as: :json
    end
    assert_response :no_content
    assert required_point.reload.present?, "required_point must survive when owner is deleted"
  end

  private

  def create_point(name)
    GeoPoint.create!(
      geo_project:       @project,
      name:              name,
      latitude:          -34.0,
      longitude:         -58.0,
      activation_radius: 50,
      order:             GeoPoint.where(geo_project: @project).count,
      active:            true
    )
  end
end
