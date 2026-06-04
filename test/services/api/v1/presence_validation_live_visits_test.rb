require "test_helper"

# Tests for the live_visits_minimum step (Step 5) of PresenceValidationService.
# Covers failure_reason, checks fields, analytics context_metadata, and
# correct ordering relative to quota and dwell.
class Api::V1::PresenceValidationLiveVisitsTest < ActiveSupport::TestCase
  LAT = -33.437
  LNG = -70.650

  setup do
    @org     = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Test", status: "active")
    @point   = GeoPoint.create!(
      geo_project: @project,
      latitude:    LAT,
      longitude:   LNG,
      availability: {
        "live_visits_enabled" => true,
        "live_visits_minimum" => 3
      }
    )
    @credential = ApiCredential.create!(
      organization:      @org,
      name:              "Test Cred",
      key_public:        "ubk_live_test_#{SecureRandom.hex(6)}",
      key_secret_digest: Digest::SHA256.hexdigest("secret"),
      scopes:            ["presence:validate"],
      status:            "active"
    )
  end

  teardown do
    AnalyticsEvent.delete_all
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    ApiCredential.delete_all
    Organization.delete_all
  end

  # ── Disabled condition passes through ──────────────────────────────────────

  test "skips live_visits check when disabled and returns valid" do
    @point.update_column(:availability, { "live_visits_enabled" => false })
    result = call_service(dry_run: true)
    assert result.valid
    assert_equal true, result.checks[:live_visits_met]
    assert_nil result.failure_reason
  end

  # ── Failure: minimum not reached ──────────────────────────────────────────

  test "returns minimum_live_visits_not_reached when count is below minimum" do
    # 1 active visit + 1 current user = 2 < 3 → fail
    create_live_visit("s1")
    result = call_service(dry_run: true)
    refute result.valid
    assert_equal "minimum_live_visits_not_reached", result.failure_reason
  end

  test "populates live_visits checks on failure" do
    create_live_visit("s1")
    result = call_service(dry_run: true)
    assert_equal true,  result.checks[:live_visits_enabled]
    assert_equal 3,     result.checks[:live_visits_required]
    assert_equal 1,     result.checks[:live_visits_current]
    assert_equal false, result.checks[:live_visits_met]
  end

  # ── Success: minimum met ───────────────────────────────────────────────────

  test "returns valid when current_count + current_user meets minimum" do
    # 2 active visits + 1 current user = 3 = minimum → ok
    create_live_visit("s1")
    create_live_visit("s2")
    result = call_service(dry_run: true)
    assert result.valid
    assert_equal true, result.checks[:live_visits_met]
    assert_nil result.failure_reason
  end

  test "populates live_visits checks on success" do
    create_live_visit("s1")
    create_live_visit("s2")
    result = call_service(dry_run: true)
    assert_equal true, result.checks[:live_visits_enabled]
    assert_equal 3,    result.checks[:live_visits_required]
    assert_equal 2,    result.checks[:live_visits_current]
    assert_equal true, result.checks[:live_visits_met]
  end

  # ── Expired/outside visits are not counted ────────────────────────────────

  test "does not count expired visits" do
    create_live_visit("s1", last_seen_at: 2.minutes.ago)
    create_live_visit("s2", last_seen_at: 2.minutes.ago)
    # 0 active + 1 current user = 1 < 3 → fail
    result = call_service(dry_run: true)
    refute result.valid
    assert_equal "minimum_live_visits_not_reached", result.failure_reason
    assert_equal 0, result.checks[:live_visits_current]
  end

  test "does not count outside_radius visits" do
    create_live_visit("s1", inside_radius: false)
    create_live_visit("s2", inside_radius: false)
    result = call_service(dry_run: true)
    refute result.valid
    assert_equal 0, result.checks[:live_visits_current]
  end

  # ── Quota is not consumed when live_visits fails ───────────────────────────

  test "does not consume quota when live_visits check fails" do
    @point.update_column(:availability, {
      "quota_enabled"       => true,
      "quota_limit"         => 10,
      "quota_used"          => 0,
      "live_visits_enabled" => true,
      "live_visits_minimum" => 3
    })
    create_live_visit("s1")
    call_service(dry_run: false)
    @point.reload
    assert_equal 0, @point.availability["quota_used"]
  end

  # ── Analytics context_metadata ────────────────────────────────────────────

  test "records context_metadata with live_visits counts on failure" do
    create_live_visit("s1")
    call_service(dry_run: false)
    event = AnalyticsEvent.where(
      geo_point_id:   @point.id,
      failure_reason: "minimum_live_visits_not_reached"
    ).last
    assert_not_nil event
    assert_equal 1, event.context_metadata["current_live_visits"]
    assert_equal 3, event.context_metadata["required_live_visits"]
  end

  private

  def call_service(session_id: "test-session", dry_run: true)
    Api::V1::PresenceValidationService.new(
      location:   @point,
      lat:        LAT,
      lng:        LNG,
      session_id: session_id,
      credential: @credential,
      dry_run:    dry_run
    ).call
  end

  def create_live_visit(session_id, inside_radius: true, last_seen_at: 10.seconds.ago)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @point,
      session_id:    session_id,
      lat:           LAT,
      lng:           LNG,
      inside_radius: inside_radius,
      last_seen_at:  last_seen_at
    )
  end
end
