module Api
  class LiveVisitsController < ApplicationController
    include LiveVisitsQueryable

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
  end
end
