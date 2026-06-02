module AnalyticsQueryable
  extend ActiveSupport::Concern

  # Returns an analytics_events scope for @project, optionally filtered to a
  # single geo_point.  Reads params[:point_id] (Studio) or params[:location_id]
  # (API v1) — whichever is present — so both surfaces share identical logic.
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

    scope
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
end
