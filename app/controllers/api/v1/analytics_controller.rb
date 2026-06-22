module Api
  module V1
    class AnalyticsController < BaseController
      include AnalyticsQueryable
      include LiveVisitsQueryable

      before_action -> { require_scope!("analytics:read") }
      before_action :set_project!

      # GET /api/v1/projects/:id/analytics[?location_id=UUID]
      #
      # Returns aggregate summary metrics + current live-visit state.
      # Optionally scoped to a single location via ?location_id=.
      # Identical calculations to Api::AnalyticsEventsController#stats and
      # Api::LiveVisitsController#index — served through shared concerns.
      def summary
        scope = point_scoped_events
        return if performed?

        radius_entries  = scope.where(event_type: AnalyticsEvent::ENTRY_EVENTS).count
        clicks          = scope.where(event_type: AnalyticsEvent::CONVERSION_EVENTS).count
        unique_enterers = scope.where(event_type: AnalyticsEvent::ENTRY_EVENTS).distinct.count(:session_id)
        unique_clickers = scope.where(event_type: AnalyticsEvent::CONVERSION_EVENTS).distinct.count(:session_id)
        conversion_pct  = unique_enterers > 0 ? (unique_clickers.to_f / unique_enterers * 100).round : 0

        active_inside   = GeoPointLiveVisit
                            .where(geo_project_id: @project.id)
                            .active_now
                            .inside_radius
        counts_by_point = active_inside.group(:geo_point_id).count
        points_by_id    = counts_by_point.any? ? @project.geo_points.where(id: counts_by_point.keys).index_by(&:id) : {}

        ranked = counts_by_point
          .map    { |pid, cnt| { pid: pid, point: points_by_id[pid], count: cnt } }
          .reject { |h| h[:point].nil? }
          .sort_by { |h| -h[:count] }

        active_now_count = ranked.sum { |h| h[:count] }
        most_active_pt   = ranked.first&.then do |h|
          pt = h[:point]
          { locationId: pt.id, locationName: pt.name, activeNow: h[:count] }
        end

        render_ok({
          summary: {
            radiusEntries: radius_entries,
            clicks:        clicks,
            conversionPct: conversion_pct
          },
          liveVisits: {
            activeNow:           active_now_count,
            mostActiveLocation:  most_active_pt,
            lastHourDeltaPct:    safe_last_hour_delta(active_now_count),
            peakToday:           safe_peak_today
          }
        })
      end

      # GET /api/v1/projects/:id/analytics/locations[?from=YYYY-MM-DD&to=YYYY-MM-DD]
      #
      # Returns per-location breakdown of analytics + current active sessions.
      # Identical query to Api::AnalyticsEventsController#stats_by_point plus
      # a live-visits count layer from GeoPointLiveVisit.
      # Date filter applied inside FILTER clauses to preserve zero-event rows.
      def locations
        dsql      = date_filter_sql_fragment
        entry_sql = entry_events_sql
        conv_sql  = conversion_events_sql

        rows = @project.geo_points
          .select(
            "geo_points.id",
            "geo_points.name",
            "COUNT(analytics_events.id) FILTER (WHERE analytics_events.event_type IN (#{entry_sql})#{dsql}) AS radius_entries",
            "COUNT(analytics_events.id) FILTER (WHERE analytics_events.event_type IN (#{conv_sql})#{dsql}) AS clicks",
            "COUNT(DISTINCT analytics_events.session_id) FILTER (WHERE analytics_events.event_type IN (#{entry_sql})#{dsql}) AS unique_enterers",
            "COUNT(DISTINCT analytics_events.session_id) FILTER (WHERE analytics_events.event_type IN (#{conv_sql})#{dsql}) AS unique_clickers"
          )
          .left_joins(:analytics_events)
          .group("geo_points.id", "geo_points.name")
          .order("geo_points.order")

        active_counts = GeoPointLiveVisit
                          .where(geo_project_id: @project.id)
                          .active_now
                          .inside_radius
                          .group(:geo_point_id)
                          .count

        render_ok(
          Api::V1::AnalyticsBlueprint.render_as_hash(
            rows,
            view:          :location_stats,
            active_counts: active_counts
          )
        )
      end

      # GET /api/v1/projects/:id/analytics/distribution[?location_id=UUID]
      #
      # Returns event distribution by hour-of-day, day-of-week, and geography.
      # Identical queries to by_hour, by_day, and geo_distribution in Studio.
      def distribution
        scope = point_scoped_events
        return if performed?

        hour_counts = scope.group(Arel.sql("EXTRACT(HOUR FROM created_at)::int")).count
        by_hour     = hour_counts.map { |h, c| { hour: h.to_i, count: c } }.sort_by { |h| h[:hour] }

        dow_counts  = scope.group(Arel.sql("EXTRACT(DOW FROM created_at)::int")).count
        by_dow      = dow_counts.map { |d, c| { day: d.to_i, count: c } }.sort_by { |h| h[:day] }

        render_ok({
          byHour:      by_hour,
          byDayOfWeek: by_dow,
          geo: {
            countries: geo_buckets(scope, :country),
            cities:    geo_buckets(scope, :city),
            communes:  geo_buckets(scope, :commune)
          }
        })
      end

      # GET /api/v1/projects/:id/analytics/outside_areas
      #   ?mode=historical|live    (default: historical)
      #   &from=YYYY-MM-DD         (historical only)
      #   &to=YYYY-MM-DD           (historical only)
      #
      # Returns GPS activity recorded outside all active GeoPoints of the project.
      # "Actividad registrada fuera de los GeoPoints activos del proyecto."
      # Inactive GeoPoints are excluded from the boundary check; a coordinate that
      # falls only inside inactive GeoPoints IS included in the result.
      def outside_areas
        mode   = params[:mode].to_s == "live" ? :live : :historical
        result = Api::V1::ActivityOutsideAreasService.new(
          @project,
          mode: mode,
          from: parse_date_param(:from),
          to:   parse_date_param(:to)
        ).call

        render_ok({
          mode:     mode,
          hotspots: result.hotspots.map { |h| serialize_outside_hotspot(h) },
          meta: {
            totalPoints:           result.total_points,
            outsidePoints:         result.outside_points,
            activeGeoPointsCount:  result.active_geo_points_count
          }
        })
      end

      # GET /api/v1/projects/:id/analytics/intensity
      #
      # Returns total historical radius_enter count per location with coordinates.
      # Identical query to Api::AnalyticsEventsController#historical_intensity.
      def intensity
        rows = @project.geo_points
          .select(
            "geo_points.id",
            "geo_points.name",
            "geo_points.latitude",
            "geo_points.longitude",
            "COUNT(analytics_events.id) FILTER (WHERE analytics_events.event_type IN (#{entry_events_sql})) AS entry_count"
          )
          .left_joins(:analytics_events)
          .group("geo_points.id", "geo_points.name", "geo_points.latitude", "geo_points.longitude")
          .order("geo_points.order")

        render_ok(
          Api::V1::AnalyticsBlueprint.render_as_hash(rows, view: :intensity_point)
        )
      end

      private

      def set_project!
        @project = organization_projects.includes(:user).find(params[:id])
      end

      def serialize_outside_hotspot(hotspot)
        {
          lat:          hotspot.lat,
          lng:          hotspot.lng,
          count:        hotspot.count,
          intensity:    hotspot.intensity,
          radiusMeters: hotspot.radius_meters
        }
      end

      # English 404 for API v1, overrides the Spanish default from AnalyticsQueryable.
      def analytics_point_not_found!
        render_error :not_found, "Location not found in this project"
        throw :abort
      end
    end
  end
end
