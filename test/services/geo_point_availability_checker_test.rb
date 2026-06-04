require "test_helper"

# Tests for GeoPointAvailabilityChecker — the single source of truth for
# all GeoPoint availability rules.
class GeoPointAvailabilityCheckerTest < ActiveSupport::TestCase
  LAT = -33.437
  LNG = -70.650

  setup do
    @org     = Organization.create!(name: "Checker Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Test", status: "active", organization: @org)
    @point   = GeoPoint.create!(
      geo_project:       @project,
      latitude:          LAT,
      longitude:         LNG,
      activation_radius: 100,
      availability:      {}
    )
  end

  teardown do
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
  end

  # ── Step 1: active ────────────────────────────────────────────────────────

  test "returns location_inactive when point is inactive" do
    @point.update_column(:active, false)
    result = check
    refute result.passed
    assert_equal "location_inactive", result.reason
  end

  # ── Step 2: boundary ──────────────────────────────────────────────────────

  test "returns outside_boundary when user is far from point" do
    result = check(lat: LAT + 1.0, lng: LNG + 1.0)
    refute result.passed
    assert_equal "outside_boundary", result.reason
    assert result.availability[:distance_meters].present?
    assert result.availability[:radius_meters].present?
  end

  test "sets checks boundary_type and distance_meters for radius mode" do
    result = check
    assert result.checks[:inside_boundary]
    assert_equal "radius", result.checks[:boundary_type]
    assert result.checks[:distance_meters]
  end

  # ── Step 3: schedule ──────────────────────────────────────────────────────

  test "returns outside_schedule when outside configured window" do
    @point.update_column(:availability, {
      "schedule_enabled"    => true,
      "schedule_days"       => ["Lun"],
      "schedule_start_time" => "09:00",
      "schedule_end_time"   => "18:00"
    })
    result = nil
    travel_to(Time.new(2026, 6, 6, 12, 0, 0)) { result = check }  # Saturday
    refute result.passed
    assert_equal "outside_schedule", result.reason
    refute result.checks[:schedule_active]
  end

  # ── Step 4: quota ─────────────────────────────────────────────────────────

  test "returns quota_exhausted when limit is reached" do
    @point.update_column(:availability, { "quota_enabled" => true, "quota_limit" => 5, "quota_used" => 5 })
    result = check
    refute result.passed
    assert_equal "quota_exhausted", result.reason
    assert_equal 0, result.availability[:quota_remaining]
    refute result.checks[:quota_available]
    assert_equal 0, result.checks[:quota_remaining]
  end

  test "sets quota_remaining in checks when quota active" do
    @point.update_column(:availability, { "quota_enabled" => true, "quota_limit" => 10, "quota_used" => 3 })
    result = check
    assert result.passed
    assert_equal 6, result.checks[:quota_remaining]  # consumed 1 on success
  end

  # ── Step 5: live_visits ───────────────────────────────────────────────────

  test "returns minimum_live_visits_not_reached when count is below minimum" do
    @point.update_column(:availability, { "live_visits_enabled" => true, "live_visits_minimum" => 3 })
    create_live_visit("s1")
    result = check  # 1 active + 1 current = 2 < 3
    refute result.passed
    assert_equal "minimum_live_visits_not_reached", result.reason
    assert_equal 1, result.availability[:current_live_visits]
    assert_equal 3, result.availability[:required_live_visits]
  end

  test "sets live_visits checks when condition is enabled" do
    @point.update_column(:availability, { "live_visits_enabled" => true, "live_visits_minimum" => 2 })
    create_live_visit("s1")  # 1 active + 1 current = 2 = minimum → passed
    result = check
    assert result.passed
    assert result.checks[:live_visits_enabled]
    assert_equal 2,    result.checks[:live_visits_required]
    assert_equal 1,    result.checks[:live_visits_current]
    assert result.checks[:live_visits_met]
  end

  test "skips live_visits checks and returns met=true when condition is disabled" do
    result = check
    assert_equal true, result.checks[:live_visits_met]
    refute result.checks[:live_visits_enabled]
  end

  # ── Step 6: dwell_time ────────────────────────────────────────────────────

  test "returns dwell_required when dwell is needed but not provided" do
    @point.update_columns(requires_dwell_time: true, dwell_time_seconds: 30)
    result = check(dwell_elapsed_seconds: nil)
    refute result.passed
    assert_equal "dwell_required", result.reason
    assert_equal 30, result.availability[:dwell_seconds]
    refute result.checks[:dwell_time_met]
  end

  test "returns dwell_time_not_met when elapsed is below threshold" do
    @point.update_columns(requires_dwell_time: true, dwell_time_seconds: 60)
    result = check(dwell_elapsed_seconds: 20)
    refute result.passed
    assert_equal "dwell_time_not_met", result.reason
    assert_equal 60, result.availability[:dwell_seconds]
    assert_equal 20, result.availability[:elapsed_seconds]
  end

  test "passes dwell when elapsed meets threshold" do
    @point.update_columns(requires_dwell_time: true, dwell_time_seconds: 30)
    result = check(dwell_elapsed_seconds: 30)
    assert result.passed
    assert result.checks[:dwell_time_met]
  end

  # ── Side effects on success ───────────────────────────────────────────────

  test "consumes quota on success when dry_run is false" do
    @point.update_column(:availability, { "quota_enabled" => true, "quota_limit" => 10, "quota_used" => 0 })
    check(dry_run: false)
    @point.reload
    assert_equal 1, @point.availability["quota_used"]
  end

  test "upserts live_visit on success when dry_run is false" do
    assert_difference "GeoPointLiveVisit.count", 1 do
      check(dry_run: false)
    end
    visit = GeoPointLiveVisit.find_by(geo_point: @point, session_id: "test-session")
    assert visit.inside_radius
  end

  test "does not consume quota when dry_run is true" do
    @point.update_column(:availability, { "quota_enabled" => true, "quota_limit" => 10, "quota_used" => 0 })
    check(dry_run: true)
    @point.reload
    assert_equal 0, @point.availability["quota_used"]
  end

  test "does not upsert live_visit when dry_run is true" do
    assert_no_difference "GeoPointLiveVisit.count" do
      check(dry_run: true)
    end
  end

  test "does not consume quota when checks fail" do
    @point.update_column(:availability, {
      "quota_enabled"       => true, "quota_limit" => 10, "quota_used" => 0,
      "live_visits_enabled" => true, "live_visits_minimum" => 5
    })
    check(dry_run: false)  # live_visits will fail (0 active + 1 = 1 < 5)
    @point.reload
    assert_equal 0, @point.availability["quota_used"]
  end

  # ── Full pass ─────────────────────────────────────────────────────────────

  test "returns passed with full checks hash on success" do
    result = check
    assert result.passed
    assert_nil result.reason
    assert result.checks[:location_active]
    assert result.checks[:inside_boundary]
    assert result.checks[:schedule_active]
    assert result.checks[:quota_available]
    assert result.checks[:live_visits_met]
    assert result.checks[:dwell_time_met]
  end

  private

  def check(lat: LAT, lng: LNG, dwell_elapsed_seconds: nil, dry_run: false)
    GeoPointAvailabilityChecker.new(
      geo_point:             @point,
      lat:                   lat,
      lng:                   lng,
      session_id:            "test-session",
      dwell_elapsed_seconds: dwell_elapsed_seconds,
      dry_run:               dry_run
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
