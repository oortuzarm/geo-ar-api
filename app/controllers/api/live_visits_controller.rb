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

      render json: {
        activeNow:              active_now_count,
        liveVisitsInsideAreas:  live_inside,
        liveVisitsOutsideAreas: live_outside,
        liveVisitsTotal:        live_total,
        mostActivePoint:        ranked.first,
        points:                 ranked,
        lastHourDeltaPercent:   safe_last_hour_delta(active_now_count),
        peakToday:              safe_peak_today
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

      # Fetch (session_id, lat, lng, last_seen_at) for every active row with
      # valid, non-zero coordinates — same filter as ActivityOutsideAreasService.
      rows = GeoPointLiveVisit
        .where(geo_project_id: @project.id)
        .active_now
        .where.not(lat: nil, lng: nil)
        .where("NOT (lat = 0 AND lng = 0)")
        .pluck(:session_id, :lat, :lng, :last_seen_at)

      # Keep only the most recent position per unique session.
      latest_per_session = rows
        .group_by { |sid, *| sid }
        .transform_values { |session_rows| session_rows.max_by { |*_, seen_at| seen_at } }
        .values

      live_inside = latest_per_session.count { |_, lat, lng, _|
        active_points.any? { |point| GeoEngine.inside_boundary?(point, lat, lng) }
      }

      live_total   = latest_per_session.size
      live_outside = live_total - live_inside

      [ live_inside, live_outside, live_total ]
    end
  end
end
