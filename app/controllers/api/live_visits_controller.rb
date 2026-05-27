module Api
  class LiveVisitsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_and_authorize_project!

    # GET /api/geo_projects/:id/live_visits
    # Returns how many sessions are currently inside each point's activation radius.
    def index
      active_inside = GeoPointLiveVisit
                        .where(geo_project_id: @project.id)
                        .active_now
                        .inside_radius

      counts_by_point = active_inside.group(:geo_point_id).count

      points_by_id = if counts_by_point.any?
        @project.geo_points.where(id: counts_by_point.keys).index_by(&:id)
      else
        {}
      end

      ranked = counts_by_point
        .map { |pid, cnt| { pid: pid, point: points_by_id[pid], count: cnt } }
        .reject { |h| h[:point].nil? }
        .sort_by { |h| -h[:count] }
        .map do |h|
          pt = h[:point]
          {
            id:           pt.id,
            name:         pt.name,
            lat:          pt.latitude,
            lng:          pt.longitude,
            radiusMeters: pt.activation_radius,
            activeNow:    h[:count]
          }
        end

      render json: {
        activeNow:            ranked.sum { |p| p[:activeNow] },
        mostActivePoint:      ranked.first,
        points:               ranked,
        lastHourDeltaPercent: nil,
        peakToday:            peak_today
      }
    end

    private

    def set_and_authorize_project!
      @project = GeoProject.find(params[:id])
      authorize_project!(@project)
    end

    # Returns the hour block with the most inside-radius sessions today, e.g.:
    #   { label: "18:00–19:00", count: 34 }
    # Returns nil when there are no records for today.
    def peak_today
      today_start = Time.zone.now.beginning_of_day
      today_end   = Time.zone.now.end_of_day

      # Group by truncated hour using the DB's configured timezone-aware clock.
      # DATE_TRUNC is PostgreSQL-specific and respects the session timezone.
      rows = GeoPointLiveVisit
               .where(geo_project_id: @project.id, inside_radius: true)
               .where(last_seen_at: today_start..today_end)
               .group("DATE_TRUNC('hour', last_seen_at AT TIME ZONE 'UTC' AT TIME ZONE ?)", Time.zone.name)
               .order("DATE_TRUNC('hour', last_seen_at AT TIME ZONE 'UTC' AT TIME ZONE ?) DESC", Time.zone.name)
               .count

      return nil if rows.empty?

      peak_time, count = rows.max_by { |_, cnt| cnt }
      hour_start = peak_time.is_a?(Time) ? peak_time : Time.zone.parse(peak_time.to_s)

      {
        label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
        count: count
      }
    end
  end
end
