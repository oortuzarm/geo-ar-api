# Validates whether a Smart Link can be unlocked for a given user location.
#
# Reuses GeoEngine exclusively — no parallel validation logic here.
# Any new rule added to GeoEngine is automatically inherited by Smart Links.
#
# Evaluation order per candidate geo_point:
#   1. inside_boundary?  (pre-filter — only candidates inside the area proceed)
#   2. schedule_active?
#   3. quota_available?
#   4. live_visits_available?
#   5. dwell_time_met?
#
# On success: consumes quota + updates live_visit + records analytics events.
# On failure: records smart_link_validation_failed.
class SmartLinkValidationService
  Result = Struct.new(
    :allowed,
    :destination_url,
    :matched_geo_point_id,
    :reason,
    :message,
    :availability,
    keyword_init: true
  )

  MESSAGES = {
    "outside_boundary"                => "Debes estar dentro del área para acceder.",
    "outside_schedule"                => "Esta experiencia está fuera del horario disponible.",
    "quota_exhausted"                 => "No quedan cupos disponibles.",
    "minimum_live_visits_not_reached" => "Se requiere un mínimo de personas en el área.",
    "dwell_required"                  => "Debes permanecer en el área por un tiempo mínimo.",
    "dwell_time_not_met"              => "Aún no has completado el tiempo de permanencia requerido.",
    "no_candidates"                   => "No hay puntos disponibles para este Smart Link."
  }.freeze
  private_constant :MESSAGES

  def initialize(smart_link:, lat:, lng:, session_id:, accuracy: nil, dwell_elapsed_seconds: nil)
    @smart_link            = smart_link
    @lat                   = lat.to_f
    @lng                   = lng.to_f
    @session_id            = session_id
    @accuracy              = accuracy
    @dwell_elapsed_seconds = dwell_elapsed_seconds
  end

  def call
    candidates = resolve_candidates
    return fail_result("no_candidates") if candidates.empty?

    # Sort by proximity — closest point evaluated first.
    ranked = candidates
      .map  { |p| [p, GeoEngine.distance_to(p, @lat, @lng)] }
      .sort_by { |_, dist| dist }

    inside = ranked.select { |p, _| GeoEngine.inside_boundary?(p, @lat, @lng) }

    if inside.empty?
      closest_point, dist = ranked.first
      return fail_result("outside_boundary", {
        distance_meters: dist.round(1),
        radius_meters:   closest_point.activation_radius
      })
    end

    last_failure_reason     = nil
    last_failure_availability = {}

    inside.each do |point, _|
      check = evaluate_point(point)
      if check[:passed]
        return handle_success(point)
      end
      last_failure_reason      = check[:failure_reason]
      last_failure_availability = check.reject { |k, _| k == :passed || k == :failure_reason }
    end

    fail_result(last_failure_reason, last_failure_availability)
  end

  private

  # ── Candidate resolution ───────────────────────────────────────────────────

  def resolve_candidates
    case @smart_link.scope_type
    when "project"    then @smart_link.project.geo_points.where(active: true).to_a
    when "geo_points" then @smart_link.geo_points.where(active: true).to_a
    else []
    end
  end

  # ── Per-point evaluation (no side effects) ────────────────────────────────

  def evaluate_point(point)
    return { passed: false, failure_reason: "location_inactive" } unless point.active

    unless GeoEngine.schedule_active?(point)
      return { passed: false, failure_reason: "outside_schedule" }
    end

    unless GeoEngine.quota_available?(point)
      return { passed: false, failure_reason: "quota_exhausted", quota_remaining: 0 }
    end

    if GeoEngine.live_visits_enabled?(point)
      current_count = GeoEngine.live_visits_count(point)
      minimum       = GeoEngine.live_visits_minimum(point)
      unless (current_count + 1) >= minimum
        return {
          passed:                false,
          failure_reason:        "minimum_live_visits_not_reached",
          current_live_visits:   current_count,
          required_live_visits:  minimum
        }
      end
    end

    if point.requires_dwell_time
      if @dwell_elapsed_seconds.nil?
        return { passed: false, failure_reason: "dwell_required",
                 dwell_seconds: point.dwell_time_seconds }
      elsif @dwell_elapsed_seconds.to_i < point.dwell_time_seconds
        return { passed: false, failure_reason: "dwell_time_not_met",
                 dwell_seconds:    point.dwell_time_seconds,
                 elapsed_seconds:  @dwell_elapsed_seconds.to_i }
      end
    end

    { passed: true }
  end

  # ── Success path ───────────────────────────────────────────────────────────

  def handle_success(point)
    if GeoEngine.quota_active?(point)
      unless GeoEngine.consume_quota!(point)
        return fail_result("quota_exhausted")
      end
    end

    update_live_visit(point)

    record_event("smart_link_validation_passed", geo_point_id: point.id,
                 geo_project_id: point.geo_project_id)

    Result.new(
      allowed:              true,
      destination_url:      @smart_link.destination_url,
      matched_geo_point_id: point.id,
      reason:               nil,
      message:              nil,
      availability:         {}
    )
  end

  # ── Failure path ──────────────────────────────────────────────────────────

  def fail_result(reason, availability = {})
    record_event("smart_link_validation_failed", failure_reason: reason,
                 geo_project_id: @smart_link.project_id)
    Result.new(
      allowed:              false,
      destination_url:      nil,
      matched_geo_point_id: nil,
      reason:               reason,
      message:              MESSAGES[reason] || "El acceso no está disponible en este momento.",
      availability:         availability
    )
  end

  # ── Side effects ──────────────────────────────────────────────────────────

  def update_live_visit(point)
    visit = GeoPointLiveVisit.find_or_initialize_by(
      geo_point_id: point.id,
      session_id:   @session_id
    )
    visit.assign_attributes(
      geo_project_id: point.geo_project_id,
      lat:            @lat,
      lng:            @lng,
      accuracy:       @accuracy,
      inside_radius:  true,
      last_seen_at:   Time.current
    )
    visit.save!
  rescue => e
    Rails.logger.warn "[SMART_LINK] Live visit update failed: #{e.class}: #{e.message}"
  end

  def record_event(event_type, geo_point_id: nil, geo_project_id: nil, failure_reason: nil)
    AnalyticsEvent.create!(
      geo_project_id:   geo_project_id || @smart_link.project_id,
      geo_point_id:     geo_point_id,
      event_type:       event_type,
      session_id:       @session_id,
      event_date:       Date.current,
      source:           "smart_link",
      failure_reason:   failure_reason,
      context_metadata: {
        smart_link_id:     @smart_link.id,
        smart_link_slug:   @smart_link.slug,
        organization_id:   @smart_link.organization_id,
        organization_slug: @smart_link.organization.slug
      }
    )
  rescue => e
    Rails.logger.error "[SMART_LINK] Event recording failed: #{e.class}: #{e.message}"
  end
end
