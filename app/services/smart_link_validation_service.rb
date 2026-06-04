# Validates whether a Smart Link can be unlocked for a given user location.
#
# Availability evaluation per candidate point is fully delegated to
# GeoPointAvailabilityChecker — this service owns only Smart-Link-specific
# concerns:
#   - candidate resolution (scope_type project / geo_points)
#   - proximity ranking
#   - outside-all-boundaries detection
#   - analytics event recording (smart_link_*)
#   - destination_url and organisation context in the response
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

    last_check = nil

    inside.each do |point, _|
      check = GeoPointAvailabilityChecker.new(
        geo_point:             point,
        lat:                   @lat,
        lng:                   @lng,
        session_id:            @session_id,
        accuracy:              @accuracy,
        dwell_elapsed_seconds: @dwell_elapsed_seconds
      ).call

      if check.passed
        # Checker already consumed quota + upserted live_visit.
        record_event("smart_link_validation_passed", geo_point_id: point.id,
                     geo_project_id: point.geo_project_id)
        return Result.new(
          allowed:              true,
          destination_url:      @smart_link.destination_url,
          matched_geo_point_id: point.id,
          reason:               nil,
          message:              nil,
          availability:         {}
        )
      end

      last_check = check
    end

    fail_result(last_check.reason, last_check.availability)
  end

  private

  # ── Candidate resolution ──────────────────────────────────────────────────

  def resolve_candidates
    case @smart_link.scope_type
    when "project"    then @smart_link.project.geo_points.where(active: true).to_a
    when "geo_points" then @smart_link.geo_points.where(active: true).to_a
    else []
    end
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

  # ── Analytics ─────────────────────────────────────────────────────────────

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
