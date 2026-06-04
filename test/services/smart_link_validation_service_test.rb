require "test_helper"

class SmartLinkValidationServiceTest < ActiveSupport::TestCase
  # Point at origin with 100m radius — user at same coords is always inside.
  LAT = -33.437
  LNG = -70.650

  setup do
    @user    = User.create!(email: "svc_sl_#{SecureRandom.hex(4)}@example.com",
                             password: "pw", role: "user", status: "active")
    @project = GeoProject.create!(title: "Test", status: "active", user: @user)
    @point   = GeoPoint.create!(
      geo_project:       @project,
      latitude:          LAT,
      longitude:         LNG,
      activation_radius: 100,
      availability:      {}
    )
    @smart_link = SmartLink.create!(
      user:            @user,
      project:         @project,
      name:            "Test Link",
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
    User.where(email: @user.email).destroy_all
  end

  # ── Success paths ──────────────────────────────────────────────────────────

  test "returns allowed when inside boundary with no restrictions" do
    result = call_service
    assert result.allowed
    assert_equal "https://example.com/destination", result.destination_url
    assert_equal @point.id, result.matched_geo_point_id
    assert_nil result.reason
  end

  test "records smart_link_validation_passed on success" do
    call_service
    assert AnalyticsEvent.exists?(event_type: "smart_link_validation_passed",
                                  source: "smart_link", geo_point_id: @point.id)
    refute AnalyticsEvent.exists?(event_type: "smart_link_redirected", source: "smart_link")
  end

  test "analytics events include smart_link_id and slug in context_metadata" do
    call_service
    event = AnalyticsEvent.find_by(event_type: "smart_link_validation_passed")
    assert_equal @smart_link.id,   event.context_metadata["smart_link_id"]
    assert_equal @smart_link.slug, event.context_metadata["smart_link_slug"]
  end

  test "updates live_visit on success" do
    assert_difference "GeoPointLiveVisit.count", 1 do
      call_service
    end
    visit = GeoPointLiveVisit.find_by(geo_point: @point, session_id: "test-session")
    assert visit.inside_radius
  end

  # ── Failure: outside boundary ──────────────────────────────────────────────

  test "returns outside_boundary when user is far from point" do
    result = call_service(lat: LAT + 1.0, lng: LNG + 1.0)
    refute result.allowed
    assert_equal "outside_boundary", result.reason
  end

  test "records smart_link_validation_failed on outside_boundary" do
    call_service(lat: LAT + 1.0, lng: LNG + 1.0)
    assert AnalyticsEvent.exists?(event_type: "smart_link_validation_failed",
                                  failure_reason: "outside_boundary", source: "smart_link")
  end

  # ── Failure: schedule ─────────────────────────────────────────────────────

  test "returns outside_schedule when schedule does not allow access" do
    # Mondays 09:00-18:00 only; 2026-06-06 is a Saturday → always outside schedule.
    @point.update_column(:availability, {
      "schedule_enabled"    => true,
      "schedule_days"       => ["Lun"],
      "schedule_start_time" => "09:00",
      "schedule_end_time"   => "18:00"
    })
    result = nil
    travel_to(Time.new(2026, 6, 6, 12, 0, 0)) { result = call_service }
    refute result.allowed
    assert_equal "outside_schedule", result.reason
  end

  # ── Failure: quota ────────────────────────────────────────────────────────

  test "returns quota_exhausted when quota is full" do
    @point.update_column(:availability, {
      "quota_enabled" => true, "quota_limit" => 5, "quota_used" => 5
    })
    result = call_service
    refute result.allowed
    assert_equal "quota_exhausted", result.reason
  end

  test "does not consume quota on outside_boundary failure" do
    @point.update_column(:availability, {
      "quota_enabled" => true, "quota_limit" => 10, "quota_used" => 0
    })
    call_service(lat: LAT + 1.0, lng: LNG + 1.0)
    @point.reload
    assert_equal 0, @point.availability["quota_used"]
  end

  test "consumes quota on success" do
    @point.update_column(:availability, {
      "quota_enabled" => true, "quota_limit" => 10, "quota_used" => 0
    })
    call_service
    @point.reload
    assert_equal 1, @point.availability["quota_used"]
  end

  # ── Failure: live_visits ──────────────────────────────────────────────────

  test "returns minimum_live_visits_not_reached when not enough active visitors" do
    @point.update_column(:availability, {
      "live_visits_enabled" => true, "live_visits_minimum" => 3
    })
    GeoPointLiveVisit.create!(geo_project: @project, geo_point: @point,
                               session_id: "other-1", lat: LAT, lng: LNG,
                               inside_radius: true, last_seen_at: 5.seconds.ago)
    # 1 active + 1 current = 2 < 3
    result = call_service
    refute result.allowed
    assert_equal "minimum_live_visits_not_reached", result.reason
  end

  # ── scope_type = geo_points ───────────────────────────────────────────────

  test "scope geo_points uses only associated points" do
    other_point = GeoPoint.create!(geo_project: @project, latitude: LAT + 1.0,
                                    longitude: LNG + 1.0, activation_radius: 100)
    @smart_link.update_column(:scope_type, "geo_points")
    @smart_link.smart_link_geo_points.create!(geo_point_id: other_point.id)

    # User is at LAT/LNG — inside @point but NOT inside other_point.
    # Since only other_point is associated, result should be outside_boundary.
    result = call_service
    refute result.allowed
    assert_equal "outside_boundary", result.reason
    # Let teardown delete SmartLinkGeoPoint before GeoPoint to avoid FK violation.
  end

  test "scope geo_points returns allowed when user is inside associated point" do
    @smart_link.update_column(:scope_type, "geo_points")
    @smart_link.smart_link_geo_points.create!(geo_point_id: @point.id)

    result = call_service
    assert result.allowed
    assert_equal @point.id, result.matched_geo_point_id
  end

  # ── No candidates ─────────────────────────────────────────────────────────

  test "returns no_candidates when project has no active points" do
    @point.update_column(:active, false)
    result = call_service
    refute result.allowed
    assert_equal "no_candidates", result.reason
  end

  private

  def call_service(lat: LAT, lng: LNG)
    SmartLinkValidationService.new(
      smart_link: @smart_link,
      lat:        lat,
      lng:        lng,
      session_id: "test-session"
    ).call
  end
end
