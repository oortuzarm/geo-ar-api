require "test_helper"

class GeoEngineLiveVisitsTest < ActiveSupport::TestCase
  setup do
    @project = GeoProject.create!(title: "Test Project", status: "active")
    @point   = GeoPoint.create!(
      geo_project:      @project,
      latitude:         -33.437,
      longitude:        -70.650,
      availability:     {}
    )
  end

  teardown do
    GeoPointLiveVisit.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
  end

  # ── live_visits_enabled? ───────────────────────────────────────────────────

  test "live_visits_enabled? returns false when not configured" do
    refute GeoEngine.live_visits_enabled?(@point)
  end

  test "live_visits_enabled? returns false when explicitly false" do
    @point.availability = { "live_visits_enabled" => false }
    refute GeoEngine.live_visits_enabled?(@point)
  end

  test "live_visits_enabled? returns true when set to true" do
    @point.availability = { "live_visits_enabled" => true }
    assert GeoEngine.live_visits_enabled?(@point)
  end

  # ── live_visits_minimum ────────────────────────────────────────────────────

  test "live_visits_minimum returns 0 when not configured" do
    assert_equal 0, GeoEngine.live_visits_minimum(@point)
  end

  test "live_visits_minimum returns configured value" do
    @point.availability = { "live_visits_minimum" => 5 }
    assert_equal 5, GeoEngine.live_visits_minimum(@point)
  end

  # ── live_visits_count ──────────────────────────────────────────────────────

  test "live_visits_count returns 0 when no visits exist" do
    assert_equal 0, GeoEngine.live_visits_count(@point)
  end

  test "live_visits_count counts only active inside_radius visits" do
    create_live_visit(session_id: "s1", inside_radius: true,  last_seen_at: 10.seconds.ago)
    create_live_visit(session_id: "s2", inside_radius: false, last_seen_at: 10.seconds.ago)
    assert_equal 1, GeoEngine.live_visits_count(@point)
  end

  test "live_visits_count does not count expired visits" do
    create_live_visit(session_id: "s1", inside_radius: true, last_seen_at: 2.minutes.ago)
    assert_equal 0, GeoEngine.live_visits_count(@point)
  end

  test "live_visits_count does not count visits from other geo_points" do
    other_point = GeoPoint.create!(geo_project: @project, latitude: -33.5, longitude: -70.7, availability: {})
    GeoPointLiveVisit.create!(
      geo_project:  @project,
      geo_point:    other_point,
      session_id:   "s-other",
      lat:          -33.5,
      lng:          -70.7,
      inside_radius: true,
      last_seen_at: 10.seconds.ago
    )
    assert_equal 0, GeoEngine.live_visits_count(@point)
  end

  # ── live_visits_available? ─────────────────────────────────────────────────

  test "live_visits_available? returns true when condition is disabled" do
    @point.availability = { "live_visits_enabled" => false }
    assert GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? returns true when minimum is 0" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 0 }
    assert GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? allows access when current_count + current_user meets minimum" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 5 }
    4.times { |i| create_live_visit(session_id: "s#{i}", inside_radius: true, last_seen_at: 10.seconds.ago) }
    # 4 existing + 1 current user = 5 = minimum → allowed
    assert GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? denies when current_count + current_user is below minimum" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 5 }
    3.times { |i| create_live_visit(session_id: "s#{i}", inside_radius: true, last_seen_at: 10.seconds.ago) }
    # 3 existing + 1 current user = 4 < 5 → denied
    refute GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? does not count expired visits toward minimum" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 2 }
    create_live_visit(session_id: "s1", inside_radius: true, last_seen_at: 2.minutes.ago)
    # 0 active + 1 current user = 1 < 2 → denied
    refute GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? does not count outside_radius visits toward minimum" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 2 }
    create_live_visit(session_id: "s1", inside_radius: false, last_seen_at: 10.seconds.ago)
    # 0 inside + 1 current user = 1 < 2 → denied
    refute GeoEngine.live_visits_available?(@point)
  end

  test "live_visits_available? with include_current_user false counts only existing visits" do
    @point.availability = { "live_visits_enabled" => true, "live_visits_minimum" => 1 }
    assert GeoEngine.live_visits_available?(@point, include_current_user: false) == false
    create_live_visit(session_id: "s1", inside_radius: true, last_seen_at: 10.seconds.ago)
    assert GeoEngine.live_visits_available?(@point, include_current_user: false)
  end

  private

  def create_live_visit(session_id:, inside_radius:, last_seen_at:)
    GeoPointLiveVisit.create!(
      geo_project:   @project,
      geo_point:     @point,
      session_id:    session_id,
      lat:           -33.437,
      lng:           -70.650,
      inside_radius: inside_radius,
      last_seen_at:  last_seen_at
    )
  end
end
