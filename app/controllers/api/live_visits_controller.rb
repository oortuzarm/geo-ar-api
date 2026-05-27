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

      active_now_count = ranked.sum { |p| p[:activeNow] }

      render json: {
        activeNow:            active_now_count,
        mostActivePoint:      ranked.first,
        points:               ranked,
        lastHourDeltaPercent: safe_last_hour_delta(active_now_count),
        peakToday:            safe_peak_today
      }
    end

    private

    def set_and_authorize_project!
      @project = GeoProject.find(params[:id])
      authorize_project!(@project)
    end

    def safe_last_hour_delta(active_now_count)
      last_hour_delta_percent(active_now_count)
    rescue => e
      Rails.logger.error "[LIVE_VISITS] last_hour_delta failed: #{e.class}: #{e.message}"
      nil
    end

    # Compares active_now against sessions recorded in the previous hour window.
    #
    # active_now    — already-computed count (inside_radius + active window).
    # previous      — distinct sessions with inside_radius=true whose last_seen_at
    #                 falls in [1.hour.ago, ACTIVE_WINDOW.ago), i.e. the hour before
    #                 the current active window. Excluding the active window avoids
    #                 counting the same sessions in both buckets.
    #
    # Formula:
    #   previous > 0  → ((now - previous) / previous.to_f * 100).round
    #   previous == 0, now > 0  → 100
    #   both zero               → 0
    def last_hour_delta_percent(active_now_count)
      active_window_cutoff    = GeoPointLiveVisit::ACTIVE_WINDOW.ago
      previous_window_cutoff  = 1.hour.ago

      previous_count = GeoPointLiveVisit
                         .where(geo_project_id: @project.id, inside_radius: true)
                         .where(last_seen_at: previous_window_cutoff...active_window_cutoff)
                         .count

      if previous_count > 0
        ((active_now_count - previous_count) / previous_count.to_f * 100).round
      elsif active_now_count > 0
        100
      else
        0
      end
    end

    # Wraps peak_today so a calculation error never takes down the whole endpoint.
    def safe_peak_today
      peak_today
    rescue => e
      Rails.logger.error "[LIVE_VISITS] peak_today failed: #{e.class}: #{e.message}"
      nil
    end

    # Resolves the timezone to use for peak_today calculations.
    # Priority: owner's saved time_zone → server Time.zone fallback.
    # ActiveSupport::TimeZone[] returns nil for unknown/invalid names, so any
    # bad value stored in users.time_zone falls through to the server default.
    def project_time_zone
      owner_tz = @project.user&.time_zone.presence
      ActiveSupport::TimeZone[owner_tz] || Time.zone
    end

    # Returns the hour block with the most inside-radius sessions today, e.g.:
    #   { label: "14:00–15:00", count: 34 }
    # Returns nil when there are no inside-radius records for today.
    #
    # "Today" and hour labels are expressed in the project owner's timezone.
    # Grouping is done in Ruby (not DATE_TRUNC) because Rails does not support
    # bind parameters inside group() clauses.
    def peak_today
      tz  = project_time_zone
      now = Time.current.in_time_zone(tz)

      today_start = now.beginning_of_day
      today_end   = now.end_of_day

      timestamps = GeoPointLiveVisit
                     .where(geo_project_id: @project.id, inside_radius: true)
                     .where(last_seen_at: today_start..today_end)
                     .pluck(:last_seen_at)

      return nil if timestamps.empty?

      counts_by_hour = timestamps
                         .group_by { |ts| ts.in_time_zone(tz).beginning_of_hour }
                         .transform_values(&:count)

      hour_start, count = counts_by_hour.max_by { |_, cnt| cnt }

      {
        label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
        count: count
      }
    end
  end
end
