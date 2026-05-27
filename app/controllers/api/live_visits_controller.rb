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
        peakToday:            safe_peak_today
      }
    end

    private

    def set_and_authorize_project!
      @project = GeoProject.find(params[:id])
      authorize_project!(@project)
    end

    # Wraps peak_today so a calculation error never takes down the whole endpoint.
    def safe_peak_today
      peak_today
    rescue => e
      Rails.logger.error "[LIVE_VISITS] peak_today failed: #{e.class}: #{e.message}"
      nil
    end

    # Returns the hour block with the most inside-radius sessions today, e.g.:
    #   { label: "18:00–19:00", count: 34 }
    # Returns nil when there are no inside-radius records today.
    #
    # Grouping is done in Ruby rather than via DATE_TRUNC so that:
    #   a) bind parameters inside group() are avoided (not supported by Rails), and
    #   b) timezone handling uses Time.zone consistently without DB-level tz strings.
    # Record volume is bounded: geo_point_live_visits is upserted per session per
    # point, so row counts per project per day remain small even for busy projects.
    def peak_today
      today_start = Time.zone.now.beginning_of_day
      today_end   = Time.zone.now.end_of_day

      timestamps = GeoPointLiveVisit
                     .where(geo_project_id: @project.id, inside_radius: true)
                     .where(last_seen_at: today_start..today_end)
                     .pluck(:last_seen_at)

      return nil if timestamps.empty?

      counts_by_hour = timestamps
                         .group_by { |ts| ts.in_time_zone(Time.zone).beginning_of_hour }
                         .transform_values(&:count)

      hour_start, count = counts_by_hour.max_by { |_, cnt| cnt }

      {
        label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
        count: count
      }
    end
  end
end
