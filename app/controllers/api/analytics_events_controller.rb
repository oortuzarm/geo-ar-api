module Api
  class AnalyticsEventsController < ApplicationController
    ANALYTICS_ACTIONS = %i[stats stats_by_point by_hour by_day geo_distribution].freeze

    before_action :authenticate_user!,         only: ANALYTICS_ACTIONS
    before_action :set_and_authorize_project!, only: ANALYTICS_ACTIONS

    # POST /api/analytics_events
    # Body (camelCase — normalize_params converts to snake_case):
    #   { projectId, pointId, eventType, sessionId, latitude?, longitude? }
    #
    # radius_enter → deduplicated: 1 record per (session, project, point, day).
    # point_click  → NOT deduplicated: every real click creates a new record.
    #
    # After saving, reverse-geocodes lat/lng in a background thread (fire-and-forget).
    def create
      event_type = params[:event_type]

      if event_type == "point_click"
        # Every click is a distinct event — no deduplication by session or day.
        event = AnalyticsEvent.new(
          geo_project_id: params[:project_id],
          geo_point_id:   params[:point_id],
          event_type:     "point_click",
          session_id:     params[:session_id],
          event_date:     Date.current,
          latitude:       params[:latitude].presence&.to_f,
          longitude:      params[:longitude].presence&.to_f,
        )
        event.save!
        geocode_async(event) if event.latitude && event.longitude
        render json: { success: true, created: true }, status: :created

      else
        # radius_enter (and any future types): deduplicated per session+day.
        attrs = {
          geo_project_id: params[:project_id],
          geo_point_id:   params[:point_id],
          event_type:     event_type,
          session_id:     params[:session_id],
          event_date:     Date.current
        }

        event = AnalyticsEvent.find_or_initialize_by(attrs)

        if event.persisted?
          render json: { success: true, created: false }
          return
        end

        event.latitude  = params[:latitude].presence&.to_f
        event.longitude = params[:longitude].presence&.to_f
        event.save!

        geocode_async(event) if event.latitude && event.longitude
        render json: { success: true, created: true }, status: :created
      end
    end

    # GET /api/geo_projects/:id/analytics[?point_id=UUID]
    def stats
      scope = point_scoped_events

      radius_entries  = scope.where(event_type: "radius_enter").count
      clicks          = scope.where(event_type: "point_click").count

      # Conversion = unique sessions that clicked ÷ unique sessions that entered.
      # Uses distinct session_id so the rate is always 0–100% and represents
      # "people converted", not raw click intensity.
      unique_enterers = scope.where(event_type: "radius_enter").distinct.count(:session_id)
      unique_clickers = scope.where(event_type: "point_click").distinct.count(:session_id)
      conversion      = unique_enterers > 0 ? (unique_clickers.to_f / unique_enterers * 100).round : 0

      render json: {
        radiusEntries: radius_entries,
        clicks:        clicks,
        conversion:    conversion
      }
    end

    # GET /api/geo_projects/:id/analytics_by_point
    # Single query: LEFT JOIN + conditional COUNT FILTER — no N+1.
    # Includes points with 0 events so the frontend always gets a complete list.
    # Conversion uses distinct session counts so it is always 0–100%.
    def stats_by_point
      rows = @project.geo_points
        .select(
          "geo_points.id",
          "geo_points.name",
          "COUNT(analytics_events.id) FILTER (WHERE analytics_events.event_type = 'radius_enter') AS radius_entries",
          "COUNT(analytics_events.id) FILTER (WHERE analytics_events.event_type = 'point_click') AS clicks",
          "COUNT(DISTINCT analytics_events.session_id) FILTER (WHERE analytics_events.event_type = 'radius_enter') AS unique_enterers",
          "COUNT(DISTINCT analytics_events.session_id) FILTER (WHERE analytics_events.event_type = 'point_click') AS unique_clickers",
        )
        .left_joins(:analytics_events)
        .group("geo_points.id", "geo_points.name")
        .order("geo_points.order")

      points = rows.map do |row|
        re            = row.radius_entries.to_i
        cl            = row.clicks.to_i
        u_enterers    = row.unique_enterers.to_i
        u_clickers    = row.unique_clickers.to_i
        conversion    = u_enterers > 0 ? (u_clickers.to_f / u_enterers * 100).round : 0

        {
          pointId:       row.id,
          pointName:     row.name,
          radiusEntries: re,
          clicks:        cl,
          conversion:    conversion
        }
      end

      render json: { points: points }
    end

    # GET /api/geo_projects/:id/analytics_by_hour[?point_id=UUID]
    # Returns event count grouped by hour of day (0..23, UTC).
    # Optional point_id query param narrows results to a single geo_point.
    # Format: { data: [{ hour: 0, count: 12 }, ...] }
    def by_hour
      scope  = point_scoped_events
      counts = scope.group(Arel.sql("EXTRACT(HOUR FROM created_at)::int")).count
      data   = counts.map { |hour, count| { hour: hour.to_i, count: count } }
                     .sort_by { |h| h[:hour] }
      render json: { data: data }
    end

    # GET /api/geo_projects/:id/analytics_by_day[?point_id=UUID]
    # Returns event count grouped by day of week (0=Sunday..6=Saturday, matches JS getDay()).
    # Optional point_id query param narrows results to a single geo_point.
    # Format: { data: [{ day: 0, count: 20 }, ...] }
    def by_day
      scope  = point_scoped_events
      counts = scope.group(Arel.sql("EXTRACT(DOW FROM created_at)::int")).count
      data   = counts.map { |day, count| { day: day.to_i, count: count } }
                     .sort_by { |h| h[:day] }
      render json: { data: data }
    end

    # GET /api/geo_projects/:id/analytics_geo[?point_id=UUID]
    # Returns aggregated geographic distribution (no individual lat/lng exposed).
    # Optional point_id query param narrows results to a single geo_point.
    # Format: { countries: [{label, count, pct}], cities: [...], communes: [...] }
    def geo_distribution
      base = point_scoped_events
      render json: {
        countries: geo_buckets(base, :country),
        cities:    geo_buckets(base, :city),
        communes:  geo_buckets(base, :commune)
      }
    end

    private

    def set_and_authorize_project!
      @project = GeoProject.find(params[:id])
      authorize_project!(@project)
    end

    # Returns analytics_events scoped to the project, optionally filtered by
    # a single geo_point when ?point_id= is present in the query string.
    # Validates that the requested point belongs to this project to prevent data leaks.
    def point_scoped_events
      scope = @project.analytics_events

      if params[:point_id].present?
        Rails.logger.info "[ANALYTICS_POINT_FILTER] action=#{action_name} " \
                          "project_id=#{@project.id} point_id=#{params[:point_id]}"

        unless @project.geo_points.exists?(id: params[:point_id])
          render json: { error: "El punto no pertenece a este proyecto." }, status: :not_found
          throw :abort
        end

        scope = scope.where(geo_point_id: params[:point_id])
        Rails.logger.info "[ANALYTICS_POINT_FILTER_APPLIED] geo_point_id=#{params[:point_id]}"
      end

      scope
    end

    # Aggregates a text column into [{label, count, pct}], sorted by count desc.
    # Excludes NULL and blank values.
    def geo_buckets(scope, column)
      rows  = scope.where.not(column => [ nil, "" ])
                   .group(column)
                   .order("count_all DESC")
                   .count
      total = rows.values.sum
      rows.map do |label, count|
        pct = total > 0 ? (count.to_f / total * 100).round : 0
        { label: label, count: count, pct: pct }
      end
    end

    # Spawns a fire-and-forget thread to reverse-geocode and update the event.
    # Uses a new DB connection from the pool; releases it on completion.
    def geocode_async(event)
      event_id = event.id
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          geo = NominatimGeocoder.reverse(event.latitude, event.longitude)
          if geo
            AnalyticsEvent.where(id: event_id).update_all(
              country: geo[:country],
              city:    geo[:city],
              commune: geo[:commune],
            )
          end
        end
      rescue => e
        Rails.logger.error "[geocode_async] #{e.class}: #{e.message}"
      end
    end
  end
end
