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
    # A session is classified as "inside" if ANY of its coordinates during the
    # period falls inside at least one active GeoPoint boundary.  It is
    # classified as "outside" if ANY of its coordinates falls outside all active
    # boundaries.  A session can belong to both groups.
    # total = |inside ∪ outside| (union, not sum — avoids double-counting).
    def period_people_counts
      from = parse_date_param(:from)
      to   = parse_date_param(:to)

      active_points = @project.geo_points.where(active: true).to_a

      scope = AnalyticsEvent
        .where(geo_project_id: @project.id)
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

      inside_sessions  = Set.new
      outside_sessions = Set.new

      coords_by_session.each do |session_id, coords|
        coords.each do |lat, lng|
          if active_points.any? { |pt| GeoEngine.inside_boundary?(pt, lat, lng) }
            inside_sessions << session_id
          else
            outside_sessions << session_id
          end
          # Short-circuit once this session is in both groups.
          break if inside_sessions.include?(session_id) && outside_sessions.include?(session_id)
        end
      end

      total = (inside_sessions | outside_sessions).size

      [ inside_sessions.size, outside_sessions.size, total ]
    end

    def parse_date_param(key)
      val = params[key]
      return nil if val.blank?
      Date.parse(val.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
