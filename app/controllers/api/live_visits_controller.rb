module Api
  class LiveVisitsController < ApplicationController
    include LiveVisitsQueryable

    before_action :authenticate_user!
    before_action :set_and_authorize_project!

    # GET /api/geo_projects/:id/live_visits
    # Returns how many sessions are currently inside each point's activation radius,
    # plus a three-way breakdown: inside active areas / outside active areas / total.
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

      point_ids = counts_by_point.keys.compact

      # Per-point metrics via bulk queries (1 query each — no N+1).
      deltas_by_point = point_last_hour_deltas(point_ids, counts_by_point)
      peaks_by_point  = point_peaks_today(point_ids)

      ranked = counts_by_point
        .map { |pid, cnt| { pid: pid, point: points_by_id[pid], count: cnt } }
        .reject { |h| h[:point].nil? }
        .sort_by { |h| -h[:count] }
        .map do |h|
          pt  = h[:point]
          pid = h[:pid]
          {
            id:                   pt.id,
            name:                 pt.name,
            lat:                  pt.latitude,
            lng:                  pt.longitude,
            radiusMeters:         pt.activation_radius,
            activeNow:            h[:count],
            lastHourDeltaPercent: deltas_by_point[pid],
            peakToday:            peaks_by_point[pid]
          }
        end

      active_now_count = ranked.sum { |p| p[:activeNow] }

      live_inside, live_outside, live_total = three_way_live_counts
      period_inside, period_outside, period_total = period_people_counts

      render json: {
        activeNow:               active_now_count,
        liveVisitsInsideAreas:   live_inside,
        liveVisitsOutsideAreas:  live_outside,
        liveVisitsTotal:         live_total,
        periodPeopleInsideAreas:  period_inside,
        periodPeopleOutsideAreas: period_outside,
        periodPeopleTotal:        period_total,
        mostActivePoint:         ranked.first,
        points:                  ranked,
        lastHourDeltaPercent:    safe_last_hour_delta(active_now_count),
        peakToday:               safe_peak_today
      }
    end

    private

    def set_and_authorize_project!
      @project = GeoProject.find(params[:id])
      authorize_project!(@project)
    end

    # Returns [inside, outside, total] using the same geospatial criterion as
    # ActivityOutsideAreasService: each unique session's latest coordinates are
    # crossed against ALL active GeoPoints via GeoEngine.inside_boundary?.
    #
    # This correctly handles:
    #   - sessions whose heartbeat was sent to geo_point A but whose coordinates
    #     fall inside geo_point B's boundary (radius or polygon)
    #   - sessions inside an inactive geo_point (always counted as outside)
    #   - sessions active across multiple overlapping geo_points (counted once)
    def three_way_live_counts
      active_points = @project.geo_points.where(active: true).to_a

      # ProjectLiveVisit has a unique index on (geo_project_id, session_id), so
      # each row is already the latest position for that session — no dedup needed.
      sessions = ProjectLiveVisit
        .where(geo_project_id: @project.id)
        .active_now
        .where.not(lat: nil, lng: nil)
        .where("NOT (lat = 0 AND lng = 0)")
        .pluck(:lat, :lng)

      live_inside  = sessions.count { |lat, lng|
        active_points.any? { |point| GeoEngine.inside_boundary?(point, lat, lng) }
      }
      live_total   = sessions.size
      live_outside = live_total - live_inside

      [ live_inside, live_outside, live_total ]
    end

    # Returns [inside, outside, total] unique-person counts for the requested
    # date range, using the same geospatial criterion as three_way_live_counts
    # and ActivityOutsideAreasService.
    #
    # Only project_location events are used as the coordinate source because
    # they are the only event type that records a user's general position
    # regardless of zone membership.  Events like radius_enter or point_click
    # are only fired while already inside a boundary, so including them would
    # inflate inside_sessions and prevent outside-only sessions from appearing
    # in outside_sessions.  This also aligns the historical source with
    # ActivityOutsideAreasService#historical_coordinates.
    #
    # Classification:
    #   inside  = sessions with ≥1 coordinate inside any active GeoPoint boundary.
    #   outside = sessions that never entered any active GeoPoint boundary.
    #   total   = all sessions detected during the period.
    #   total   = inside + outside  (sets are disjoint by construction).
    def period_people_counts
      from = parse_date_param(:from)
      to   = parse_date_param(:to)

      active_points = @project.geo_points.where(active: true).to_a

      scope = AnalyticsEvent
        .where(geo_project_id: @project.id, event_type: "project_location")
        .where.not(latitude: nil, longitude: nil)
        .where(latitude: -90.0..90.0, longitude: -180.0..180.0)
        .where("NOT (latitude = 0 AND longitude = 0)")

      scope = scope.where(event_date: from..) if from
      scope = scope.where(event_date: ..to)   if to

      rows = scope.pluck(:session_id, :latitude, :longitude)

      # Group all event coordinates by session_id, then classify each session.
      coords_by_session = rows
        .group_by { |sid, _lat, _lng| sid }
        .transform_values { |r| r.map { |_sid, lat, lng| [lat, lng] } }

      inside_sessions = Set.new

      coords_by_session.each do |session_id, coords|
        # Short-circuit at the first coordinate found inside any boundary.
        if coords.any? { |lat, lng| active_points.any? { |pt| GeoEngine.inside_boundary?(pt, lat, lng) } }
          inside_sessions << session_id
        end
      end

      all_sessions     = Set.new(coords_by_session.keys)
      outside_sessions = all_sessions - inside_sessions

      [ inside_sessions.size, outside_sessions.size, all_sessions.size ]
    end

    def parse_date_param(key)
      val = params[key]
      return nil if val.blank?
      Date.parse(val.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Returns { geo_point_id => Integer | nil } for every id in point_ids.
    # nil = no snapshot found in the ±8-minute window around 1 hour ago.
    # Uses one query for all points — no N+1.
    def point_last_hour_deltas(point_ids, active_counts_by_point)
      return {} if point_ids.empty?

      target_time = 1.hour.ago

      rows = LiveVisitSnapshot
        .where(geo_project_id: @project.id)
        .where(geo_point_id: point_ids)
        .where(sampled_at: (target_time - 8.minutes)..(target_time + 8.minutes))
        .pluck(:geo_point_id, :sampled_at, :active_count)

      # Most recent snapshot's active_count per point within the window.
      past_by_point = rows
        .group_by { |pid, _ts, _cnt| pid }
        .transform_values { |group| group.max_by { |_pid, ts, _cnt| ts }.last }

      point_ids.each_with_object({}) do |pid, result|
        past_count = past_by_point[pid]
        now_count  = active_counts_by_point[pid] || 0

        result[pid] = if past_count.nil?
          nil
        elsif past_count > 0
          ((now_count - past_count) / past_count.to_f * 100).round
        elsif now_count > 0
          100
        else
          0
        end
      end
    end

    # Returns { geo_point_id => { label: String, count: Integer } } for every id
    # in point_ids that has snapshots today.  Points with no data are absent from
    # the hash, so callers get nil when accessing a missing key.
    # Uses one query for all points — no N+1.
    def point_peaks_today(point_ids)
      return {} if point_ids.empty?

      tz          = project_time_zone
      now         = Time.current.in_time_zone(tz)
      today_start = now.beginning_of_day
      today_end   = now.end_of_day

      rows = LiveVisitSnapshot
        .where(geo_project_id: @project.id)
        .where(geo_point_id: point_ids)
        .where(sampled_at: today_start..today_end)
        .pluck(:geo_point_id, :sampled_at, :active_count)

      rows.group_by { |pid, _ts, _cnt| pid }.transform_values do |group|
        counts_by_hour = group
          .group_by { |_pid, ts, _cnt| ts.in_time_zone(tz).beginning_of_hour }
          .transform_values { |g| g.map { |_pid, _ts, cnt| cnt }.max }

        hour_start, count = counts_by_hour.max_by { |_, cnt| cnt }

        {
          label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
          count: count
        }
      end
    end
  end
end
