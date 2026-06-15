# Single source of truth for GeoPoint availability evaluation.
#
# Centralises the full rule chain:
#   1. active
#   2. inside_boundary?
#   3. schedule_active?
#   4. quota_available?          (evaluate first, consume only on success)
#   5. live_visits_minimum
#   6. dwell_time
#
# All geospatial/availability functions are delegated to GeoEngine.
# Side effects (consume_quota!, GeoPointLiveVisit upsert) run only when
# every check passes AND dry_run is false.
#
# Used by:
#   - Api::V1::PresenceValidationService  (single known point)
class GeoPointAvailabilityChecker
  Result = Struct.new(
    :passed,
    :reason,       # String or nil — failure code, matches existing failure_reason values
    :checks,       # Hash — full per-check diagnostics (consumed by PresenceValidationService)
    :availability, # Hash — extra data for frontend availability messages
    keyword_init: true
  )

  def initialize(geo_point:, lat:, lng:, session_id:,
                 accuracy: nil, dwell_elapsed_seconds: nil,
                 at: Time.current, dry_run: false)
    @geo_point             = geo_point
    @lat                   = lat.to_f
    @lng                   = lng.to_f
    @session_id            = session_id
    @accuracy              = accuracy
    @dwell_elapsed_seconds = dwell_elapsed_seconds
    @at                    = at
    @dry_run               = dry_run
  end

  def call
    checks = {}

    # ── 1. Active ────────────────────────────────────────────────────────────
    checks[:location_active] = @geo_point.active
    return fail(checks, "location_inactive") unless @geo_point.active

    # ── 2. Boundary ──────────────────────────────────────────────────────────
    dist   = GeoEngine.distance_to(@geo_point, @lat, @lng)
    inside = GeoEngine.inside_boundary?(@geo_point, @lat, @lng)
    checks[:inside_boundary] = inside
    checks[:boundary_type]   = @geo_point.activation_mode
    checks[:distance_meters] = dist.round(2) if @geo_point.activation_mode == "radius"
    return fail(checks, "outside_boundary",
                { distance_meters: dist.round(1), radius_meters: @geo_point.activation_radius }) unless inside

    # ── 3. Schedule ───────────────────────────────────────────────────────────
    sched_ok = GeoEngine.schedule_active?(@geo_point, at: @at)
    checks[:schedule_active] = sched_ok
    return fail(checks, "outside_schedule") unless sched_ok

    # ── 4. Quota (evaluate — do not consume yet) ──────────────────────────────
    checks[:quota_available] = GeoEngine.quota_available?(@geo_point)
    checks[:quota_remaining] = GeoEngine.quota_remaining(@geo_point)
    return fail(checks, "quota_exhausted", { quota_remaining: 0 }) unless checks[:quota_available]

    # ── 5. Live visits minimum ────────────────────────────────────────────────
    checks[:live_visits_enabled] = GeoEngine.live_visits_enabled?(@geo_point)
    if checks[:live_visits_enabled]
      current_count = GeoEngine.live_visits_count(@geo_point)
      minimum       = GeoEngine.live_visits_minimum(@geo_point)
      checks[:live_visits_required] = minimum
      checks[:live_visits_current]  = current_count
      checks[:live_visits_met]      = (current_count + 1) >= minimum
      unless checks[:live_visits_met]
        return fail(checks, "minimum_live_visits_not_reached",
                    { current_live_visits: current_count, required_live_visits: minimum })
      end
    else
      checks[:live_visits_met] = true
    end

    # ── 6. Dwell time ─────────────────────────────────────────────────────────
    checks[:dwell_required] = @geo_point.requires_dwell_time
    if @geo_point.requires_dwell_time
      if @dwell_elapsed_seconds.nil?
        checks[:dwell_time_met] = false
        return fail(checks, "dwell_required", { dwell_seconds: @geo_point.dwell_time_seconds })
      elsif @dwell_elapsed_seconds.to_i < @geo_point.dwell_time_seconds
        checks[:dwell_time_met] = false
        return fail(checks, "dwell_time_not_met",
                    { dwell_seconds: @geo_point.dwell_time_seconds,
                      elapsed_seconds: @dwell_elapsed_seconds.to_i })
      else
        checks[:dwell_time_met] = true
      end
    else
      checks[:dwell_time_met] = true
    end

    # ── All checks passed — side effects ─────────────────────────────────────
    unless @dry_run
      if GeoEngine.quota_active?(@geo_point)
        unless GeoEngine.consume_quota!(@geo_point)
          # Race condition: quota exhausted between evaluation and consumption.
          checks[:quota_available] = false
          checks[:quota_remaining] = 0
          return fail(checks, "quota_exhausted", { quota_remaining: 0 })
        end
        checks[:quota_remaining] = GeoEngine.quota_remaining(@geo_point)
      end

      upsert_live_visit
    end

    Result.new(passed: true, reason: nil, checks: checks, availability: {})
  end

  private

  def fail(checks, reason, availability = {})
    Result.new(passed: false, reason: reason, checks: checks, availability: availability)
  end

  def upsert_live_visit
    visit = GeoPointLiveVisit.find_or_initialize_by(
      geo_point_id: @geo_point.id,
      session_id:   @session_id
    )
    visit.assign_attributes(
      geo_project_id: @geo_point.geo_project_id,
      lat:            @lat,
      lng:            @lng,
      accuracy:       @accuracy,
      inside_radius:  true,
      last_seen_at:   Time.current
    )
    visit.save!
  rescue => e
    Rails.logger.warn "[GEO_POINT_AVAILABILITY] Live visit upsert failed: #{e.class}: #{e.message}"
  end
end
