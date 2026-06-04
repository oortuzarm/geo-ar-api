module AnalyticsQueryable
  extend ActiveSupport::Concern

  # Returns an analytics_events scope for @project, optionally filtered to a
  # single geo_point AND an optional date range (params[:from] / params[:to]).
  # Reads params[:point_id] (Studio) or params[:location_id] (API v1) so both
  # surfaces share identical logic.
  def point_scoped_events
    scope = @project.analytics_events
    pid   = params[:point_id].presence || params[:location_id].presence

    if pid.present?
      Rails.logger.info "[ANALYTICS_POINT_FILTER] action=#{action_name} " \
                        "project_id=#{@project.id} point_id=#{pid}"

      unless @project.geo_points.exists?(id: pid)
        analytics_point_not_found!
        return scope
      end

      scope = scope.where(geo_point_id: pid)
      Rails.logger.info "[ANALYTICS_POINT_FILTER_APPLIED] geo_point_id=#{pid}"
    end

    date_range_scope(scope)
  end

  # Aggregates events by a text column into [{label, count, pct}], sorted desc.
  # Excludes NULL and blank values; pct is 0 when total is 0.
  def geo_buckets(scope, column)
    rows  = scope.where.not(column => [nil, ""])
                 .group(column)
                 .order("count_all DESC")
                 .count
    total = rows.values.sum
    rows.map do |label, count|
      pct = total > 0 ? (count.to_f / total * 100).round : 0
      { label: label, count: count, pct: pct }
    end
  end

  private

  # Renders a 404 and aborts when the requested point doesn't belong to the
  # project.  Override in subclasses that use a different error-rendering helper.
  def analytics_point_not_found!
    render json: { error: "El punto no pertenece a este proyecto." }, status: :not_found
    throw :abort
  end

  # Applies optional from/to date filters to an analytics_events scope.
  # Filters on event_date (DATE column) — the business date set by the client,
  # not created_at.  Invalid or absent params are silently ignored.
  def date_range_scope(scope)
    from = parse_date_param(:from)
    to   = parse_date_param(:to)
    scope = scope.where(event_date: from..) if from
    scope = scope.where(event_date: ..to)   if to
    scope
  end

  # Returns a SQL fragment suitable for appending inside a COUNT FILTER clause:
  #   " AND analytics_events.event_date >= '2026-01-01' AND analytics_events.event_date <= '2026-03-31'"
  # Returns "" when no valid date params are present.
  #
  # Used by actions that build LEFT JOIN queries with per-column FILTER WHERE
  # expressions (stats_by_point, locations).  Date values are formatted via
  # Date#to_s ("YYYY-MM-DD") — digits and hyphens only, no SQL injection risk.
  def date_filter_sql_fragment
    from = parse_date_param(:from)
    to   = parse_date_param(:to)
    parts = []
    parts << "analytics_events.event_date >= '#{from}'" if from
    parts << "analytics_events.event_date <= '#{to}'"   if to
    parts.any? ? " AND #{parts.join(' AND ')}" : ""
  end

  # Parses a query param as a Date.  Returns nil for absent, blank, or
  # malformed values so callers can silently skip the filter.
  def parse_date_param(key)
    Date.parse(params[key].to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # SQL-safe IN-list strings for unified event groups.
  # Values come from our own constants — no user input, no injection risk.
  def entry_events_sql
    AnalyticsEvent::ENTRY_EVENTS.map { |t| "'#{t}'" }.join(", ")
  end

  def conversion_events_sql
    AnalyticsEvent::CONVERSION_EVENTS.map { |t| "'#{t}'" }.join(", ")
  end
end
