module Api
  class AnalyticsEventsController < ApplicationController
    include AnalyticsQueryable

    ANALYTICS_ACTIONS = %i[stats stats_by_point by_hour by_day geo_distribution historical_intensity analytics_destinations].freeze

    before_action :authenticate_user!,         only: ANALYTICS_ACTIONS
    before_action :set_and_authorize_project!, only: ANALYTICS_ACTIONS

    # POST /api/analytics_events
    # Body (camelCase — normalize_params converts to snake_case):
    #   { projectId, pointId, eventType, sessionId, latitude?, longitude? }
    #
    # Public endpoint (no auth required) — fired by public-facing pages.
    # Hardened: validates project existence, active status, point ownership,
    # event_type allowlist, and session_id length to prevent abuse.
    #
    # radius_enter → deduplicated: 1 record per (session, project, point, day).
    # point_click  → NOT deduplicated: every real click creates a new record.
    NON_DEDUPLICATED_TYPES = %w[point_click dwell_cancelled].freeze
    private_constant :NON_DEDUPLICATED_TYPES

    # Maximum length for session_id to prevent oversized payloads.
    SESSION_ID_MAX = 128
    private_constant :SESSION_ID_MAX

    def create
      event_type = params[:event_type].to_s
      project_id = params[:project_id].to_s
      point_id   = params[:point_id].presence

      # ── Validate event_type against public-writable allowlist ───────────────
      # Smart Link event types are excluded — they are only created server-side.
      unless AnalyticsEvent::PUBLIC_WRITABLE_EVENT_TYPES.include?(event_type)
        render json: { error: "Tipo de evento no válido." }, status: :unprocessable_entity
        return
      end

      # ── Validate project_id presence ────────────────────────────────────────
      if project_id.blank?
        render json: { error: "project_id es obligatorio." }, status: :unprocessable_entity
        return
      end

      # ── Load project and verify it is published ──────────────────────────────
      project = GeoProject.find_by(id: project_id)
      unless project
        render json: { error: "Proyecto no encontrado." }, status: :not_found
        return
      end
      unless project.status == "active"
        render json: { error: "Proyecto no disponible." }, status: :unprocessable_entity
        return
      end

      # ── Validate point ownership when point_id is present ───────────────────
      if point_id.present?
        unless project.geo_points.exists?(id: point_id)
          render json: { error: "Punto no encontrado en este proyecto." }, status: :unprocessable_entity
          return
        end
      end

      # ── Sanitize session_id ──────────────────────────────────────────────────
      session_id = params[:session_id].to_s.slice(0, SESSION_ID_MAX).presence

      # ── Extract and sanitize context_metadata ────────────────────────────────
      # Only stores known, safe keys — content_type and destination_category.
      # Unknown keys are silently dropped to prevent storing arbitrary data.
      context_metadata = extract_click_context

      if NON_DEDUPLICATED_TYPES.include?(event_type)
        # Every occurrence is a distinct event — no deduplication by session or day.
        event = AnalyticsEvent.new(
          geo_project_id:   project_id,
          geo_point_id:     point_id,
          event_type:       event_type,
          session_id:       session_id,
          event_date:       Date.current,
          latitude:         params[:latitude].presence&.to_f,
          longitude:        params[:longitude].presence&.to_f,
          context_metadata: context_metadata,
        )
        event.save!
        geocode_async(event) if event.latitude && event.longitude
        render json: { success: true, created: true }, status: :created

      else
        # radius_enter, dwell_started, dwell_completed: deduplicated per session+day.
        attrs = {
          geo_project_id: project_id,
          geo_point_id:   point_id,
          event_type:     event_type,
          session_id:     session_id,
          event_date:     Date.current
        }

        event = AnalyticsEvent.find_or_initialize_by(attrs)

        if event.persisted?
          render json: { success: true, created: false }
          return
        end

        event.latitude         = params[:latitude].presence&.to_f
        event.longitude        = params[:longitude].presence&.to_f
        event.context_metadata = context_metadata
        event.save!

        geocode_async(event) if event.latitude && event.longitude
        render json: { success: true, created: true }, status: :created
      end
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first || "Evento inválido." },
             status: :unprocessable_entity
    end

    # GET /api/geo_projects/:id/analytics[?point_id=UUID]
    def stats
      scope = point_scoped_events

      radius_entries  = scope.where(event_type: AnalyticsEvent::ENTRY_EVENTS).count
      clicks          = scope.where(event_type: AnalyticsEvent::CONVERSION_EVENTS).count

      # Conversion = unique sessions that converted ÷ unique sessions that entered.
      # Counts all entry channels (map, API v1, Smart Links) as entries, and all
      # conversion channels (map clicks, API destinations) as conversions.
      unique_enterers = scope.where(event_type: AnalyticsEvent::ENTRY_EVENTS).distinct.count(:session_id)
      unique_clickers = scope.where(event_type: AnalyticsEvent::CONVERSION_EVENTS).distinct.count(:session_id)
      conversion      = unique_enterers > 0 ? (unique_clickers.to_f / unique_enterers * 100).round : 0

      render json: {
        radiusEntries: radius_entries,
        clicks:        clicks,
        conversion:    conversion
      }
    end

    # GET /api/geo_projects/:id/analytics_by_point[?from=YYYY-MM-DD&to=YYYY-MM-DD]
    # Single query: LEFT JOIN + conditional COUNT FILTER — no N+1.
    # Includes points with 0 events so the frontend always gets a complete list.
    # Conversion uses distinct session counts so it is always 0–100%.
    # Date filter is applied inside the FILTER clauses so the LEFT JOIN keeps
    # points with zero matching events (not filtered out by a WHERE clause).
    def stats_by_point
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
          "COUNT(DISTINCT analytics_events.session_id) FILTER (WHERE analytics_events.event_type IN (#{conv_sql})#{dsql}) AS unique_clickers",
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

    # GET /api/geo_projects/:id/analytics_destinations[?from=&to=&point_id=]
    #
    # Aggregates point_click events that carry context_metadata to answer:
    # "What did the user do after interacting with a location?"
    #
    # Returns:
    #   totalClicks      — all point_click events (including legacy without context)
    #   contextualClicks — subset that carries content_type/destination_category
    #   legacyClicks     — clicks without context (before Phase 1 tracking)
    #   topContentType   — most-clicked content type, or null
    #   topCategory      — most-clicked destination category, or null
    #   byContentType    — [{contentType, clicks, share}] sorted desc
    #   byCategory       — [{category, clicks, share}] sorted desc (URL type only)
    #   byLocation       — [{pointId, pointName, totalClicks, topDest,
    #                        topDestClicks, topDestShare}] sorted by totalClicks desc
    #                      topDest is destination_category when present,
    #                      falling back to content_type for non-URL clicks.
    def analytics_destinations
      clicks = point_scoped_events
      return if performed?

      clicks = clicks.where(event_type: AnalyticsEvent::CONVERSION_EVENTS)
      total  = clicks.count

      contextual = clicks.where.not(context_metadata: nil)

      # — By content type ———————————————————————————————————————————
      ct_raw   = contextual
                   .where("context_metadata->>'content_type' IS NOT NULL")
                   .group(Arel.sql("context_metadata->>'content_type'"))
                   .count
                   .sort_by { |_, n| -n }
      ct_total = ct_raw.sum { |_, n| n }
      by_ct    = ct_raw.map do |ct, n|
        { contentType: ct, clicks: n,
          share: ct_total > 0 ? (n.to_f / ct_total * 100).round : 0 }
      end

      # — By destination category (URL type only) ————————————————————
      cat_raw   = contextual
                    .where("context_metadata->>'destination_category' IS NOT NULL")
                    .group(Arel.sql("context_metadata->>'destination_category'"))
                    .count
                    .sort_by { |_, n| -n }
      cat_total = cat_raw.sum { |_, n| n }
      by_cat    = cat_raw.map do |cat, n|
        { category: cat, clicks: n,
          share: cat_total > 0 ? (n.to_f / cat_total * 100).round : 0 }
      end

      # — By location ————————————————————————————————————————————————
      # Total contextual clicks per point
      per_point_total = contextual.group(:geo_point_id).count

      # Clicks per (point, unified_dest): prefer destination_category, fall back to content_type.
      # Using COALESCE ensures non-URL clicks still appear under their content_type.
      unified_dest_sql = Arel.sql(
        "COALESCE(context_metadata->>'destination_category', context_metadata->>'content_type')"
      )
      per_point_dest = contextual
                         .where("#{unified_dest_sql} IS NOT NULL")
                         .group(:geo_point_id, unified_dest_sql)
                         .count

      # Group per_point_dest by point_id for O(1) lookup
      grouped_by_point = per_point_dest.each_with_object({}) do |((pid, dest), n), h|
        h[pid] ||= {}
        h[pid][dest] = n
      end

      # Load names only for the points that have contextual clicks
      names_by_id = @project.geo_points
                      .where(id: per_point_total.keys)
                      .pluck(:id, :name)
                      .to_h

      by_location = per_point_total.filter_map do |pid, total_pt|
        name = names_by_id[pid]
        next unless name

        dest_counts = grouped_by_point[pid] || {}
        top_dest, top_n = dest_counts.max_by { |_, n| n }

        {
          pointId:       pid,
          pointName:     name,
          totalClicks:   total_pt,
          topDest:       top_dest,
          topDestClicks: top_n || 0,
          topDestShare:  (top_dest && total_pt > 0) ? (top_n.to_f / total_pt * 100).round(1) : 0.0
        }
      end.sort_by { |loc| -loc[:totalClicks] }

      contextual_count = contextual.count

      render json: {
        totalClicks:      total,
        contextualClicks: contextual_count,
        legacyClicks:     total - contextual_count,
        topContentType:   by_ct.first&.dig(:contentType),
        topCategory:      by_cat.first&.dig(:category),
        byContentType:    by_ct,
        byCategory:       by_cat,
        byLocation:       by_location
      }
    end

    # GET /api/geo_projects/:id/historical_intensity
    # Returns total radius_enter count per geo_point across all time.
    # No date filter — the full historical record is included.
    # Format: { points: [{ pointId, pointName, lat, lng, count }] }
    def historical_intensity
      rows = @project.geo_points
        .select(
          "geo_points.id",
          "geo_points.name",
          "geo_points.latitude",
          "geo_points.longitude",
          "COUNT(analytics_events.id) AS entry_count"
        )
        .left_joins(:analytics_events)
        .where("analytics_events.id IS NULL OR analytics_events.event_type IN (#{entry_events_sql})")
        .group("geo_points.id", "geo_points.name", "geo_points.latitude", "geo_points.longitude")
        .order("geo_points.order")

      render json: {
        points: rows.map do |row|
          {
            pointId:   row.id,
            pointName: row.name,
            lat:       row.latitude,
            lng:       row.longitude,
            count:     row.entry_count.to_i
          }
        end
      }
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

    # Extracts safe, known keys from params[:context_metadata].
    # Returns a Hash with at most { "content_type" => "url", "destination_category" => "whatsapp" }
    # or nil when no valid context is present.
    # All unknown keys are dropped — this is a public endpoint and must be hardened.
    def extract_click_context
      raw = params[:context_metadata]
      return nil unless raw.is_a?(ActionController::Parameters) || raw.is_a?(Hash)

      h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.stringify_keys : raw.stringify_keys

      result = {}

      ct = h["content_type"].to_s.presence
      result["content_type"] = ct if GeoPoint::CONTENT_TYPES.include?(ct)

      dc = h["destination_category"].to_s.presence
      result["destination_category"] = dc if GeoPoint::DESTINATION_CATEGORIES.include?(dc)

      result.presence
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
