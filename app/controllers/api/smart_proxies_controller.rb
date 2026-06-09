module Api
  # Studio CRUD + analytics for Smart Proxies — session-authenticated.
  # Scoped to the current user's organization; admins see everything.
  #
  # Analytics endpoints mirror the shape of the equivalent project/point endpoints
  # so the frontend can render both surfaces with the same components.
  class SmartProxiesController < ApplicationController
    before_action :authenticate_user!
    before_action :set_smart_proxy, only: %i[
      show update destroy
      proxy_live_visits analytics analytics_intensity proxy_hotspots
    ]

    # ── CRUD ─────────────────────────────────────────────────────────────────

    # GET /api/smart_proxies
    def index
      proxies = smart_proxies_scope
                  .includes(:organization)
                  .order(created_at: :desc)
      render json: proxies.map(&:as_api_json)
    end

    # GET /api/smart_proxies/:id
    def show
      render json: @smart_proxy.as_api_json
    end

    # POST /api/smart_proxies
    def create
      org = current_organization
      return render json: { error: "No perteneces a ninguna organización." }, status: :forbidden unless org

      @smart_proxy = SmartProxy.new(
        smart_proxy_params.merge(user_id: current_user.id, organization_id: org.id)
      )

      if @smart_proxy.save
        SmartProxies::CompatibilityScanJob.perform_later(@smart_proxy.id)
        render json: @smart_proxy.reload.as_api_json, status: :created
      else
        render json: { error: @smart_proxy.errors.full_messages.first }, status: :unprocessable_entity
      end
    end

    # PATCH /api/smart_proxies/:id
    def update
      if @smart_proxy.update(smart_proxy_params)
        SmartProxies::CompatibilityScanJob.perform_later(@smart_proxy.id) if @smart_proxy.saved_change_to_destination_url?
        render json: @smart_proxy.as_api_json
      else
        render json: { error: @smart_proxy.errors.full_messages.first }, status: :unprocessable_entity
      end
    end

    # POST /api/smart_proxies/scan
    # Runs a compatibility scan against an arbitrary URL without creating a SmartProxy.
    # Used by the frontend CompatibilityPanel before/during proxy creation.
    def scan
      url = params[:destination_url].to_s.strip
      return render json: { error: "destination_url es requerido." },
                    status: :unprocessable_entity if url.blank?

      if (err = validate_scan_url(url))
        return render json: { error: err }, status: :unprocessable_entity
      end

      result = SmartProxies::CompatibilityScanner.new(url).run

      render json: {
        status:         result[:status],
        score:          result[:score],
        notes:          result.dig(:report, :notes).to_a,
        detected_risks: result.dig(:report, :detected_risks).to_a
      }
    end

    # DELETE /api/smart_proxies/:id
    def destroy
      Rails.logger.info "[SmartProxy] smart_proxy_destroy_requested proxy_id=#{@smart_proxy.id} name=#{@smart_proxy.name.inspect} user_id=#{current_user.id}"
      @smart_proxy.destroy!
      Rails.logger.info "[SmartProxy] smart_proxy_destroyed proxy_id=#{@smart_proxy.id}"
      head :no_content
    end

    # ── Live Visits ───────────────────────────────────────────────────────────

    # GET /api/smart_proxies/live_visits
    # Org-level summary: active sessions across ALL smart proxies for this org.
    # Mirrors the shape of GET /api/geo_projects/:id/live_visits.
    def live_visits
      org = current_organization
      return render json: { error: "No perteneces a ninguna organización." }, status: :forbidden unless org

      proxy_ids = org.smart_proxies.where(active: true).pluck(:id)

      active_visits = SmartProxyLiveVisit
                        .where(smart_proxy_id: proxy_ids)
                        .active_now

      counts_by_proxy = active_visits.group(:smart_proxy_id).count

      proxies_by_id = if counts_by_proxy.any?
        SmartProxy.where(id: counts_by_proxy.keys)
                  .includes(:organization)
                  .index_by(&:id)
      else
        {}
      end

      ranked = counts_by_proxy
        .map { |pid, cnt| { proxy: proxies_by_id[pid], count: cnt } }
        .reject { |h| h[:proxy].nil? }
        .sort_by { |h| -h[:count] }
        .map do |h|
          px = h[:proxy]
          {
            id:          px.id,
            name:        px.name,
            slug:        px.slug,
            publicUrl:   px.public_url,
            proxyStatus: px.proxy_status,
            activeNow:   h[:count]
          }
        end

      active_now_total = ranked.sum { |p| p[:activeNow] }

      render json: {
        activeNow:       active_now_total,
        mostActiveProxy: ranked.first,
        proxies:         ranked,
        lastHourDelta:   last_hour_delta(proxy_ids, active_now_total),
        peakToday:       peak_today(proxy_ids)
      }
    end

    # GET /api/smart_proxies/:id/live_visits
    # Per-proxy live visits — active sessions right now.
    def proxy_live_visits
      active = @smart_proxy.smart_proxy_live_visits.active_now
      count  = active.count

      render json: {
        smartProxyId: @smart_proxy.id,
        activeNow:    count,
        lastSeenAt:   active.maximum(:last_seen_at)&.iso8601,
        lastHourDelta: last_hour_delta([@smart_proxy.id], count),
        peakToday:     peak_today([@smart_proxy.id])
      }
    end

    # ── Analytics summary ─────────────────────────────────────────────────────

    # GET /api/smart_proxies/:id/analytics[?from=YYYY-MM-DD&to=YYYY-MM-DD]
    # Summary metrics for a single proxy.
    # Mirrors the shape of GET /api/geo_projects/:id/analytics.
    def analytics
      scope = proxy_events_scope

      openings          = scope.where(event_type: "smart_proxy_opened").count
      location_granted  = scope.where(event_type: "smart_proxy_location_granted").count
      clicks            = scope.where(event_type: "smart_proxy_click").count
      heartbeats        = scope.where(event_type: "smart_proxy_heartbeat").count
      dwell_completions = scope.where(event_type: "smart_proxy_dwell_completed").count

      unique_sessions   = scope.where(event_type: "smart_proxy_opened").distinct.count(:session_id)
      unique_clickers   = scope.where(event_type: "smart_proxy_click").distinct.count(:session_id)
      conversion_pct    = unique_sessions > 0 ? (unique_clickers.to_f / unique_sessions * 100).round : 0

      dwell_avg = begin
        vals = scope
          .where(event_type: "smart_proxy_dwell_completed")
          .where("context_metadata->>'dwell_seconds' IS NOT NULL")
          .pluck(Arel.sql("(context_metadata->>'dwell_seconds')::int"))
        vals.any? ? (vals.sum.to_f / vals.size).round : nil
      end

      render json: {
        smartProxyId:     @smart_proxy.id,
        openings:         openings,
        locationGranted:  location_granted,
        clicks:           clicks,
        heartbeats:       heartbeats,
        dwellCompletions: dwell_completions,
        uniqueSessions:   unique_sessions,
        uniqueClickers:   unique_clickers,
        conversionPct:    conversion_pct,
        avgDwellSeconds:  dwell_avg
      }
    end

    # ── GPS Intensity ─────────────────────────────────────────────────────────

    # GET /api/smart_proxies/:id/analytics/intensity[?from=YYYY-MM-DD&to=YYYY-MM-DD]
    # Returns lat/lng heatmap from heartbeat + location_granted events.
    # Mirrors the shape of GET /api/geo_projects/:id/historical_intensity.
    def analytics_intensity
      from = parse_date_param(:from)
      to   = parse_date_param(:to)

      scope = AnalyticsEvent
        .where(smart_proxy_id: @smart_proxy.id,
               event_type: %w[smart_proxy_heartbeat smart_proxy_location_granted])
        .where.not(latitude: nil, longitude: nil)
        .where(latitude: -90.0..90.0, longitude: -180.0..180.0)
        .where("NOT (latitude = 0 AND longitude = 0)")

      scope = scope.where(event_date: from..) if from
      scope = scope.where(event_date: ..to)   if to

      pairs = scope.pluck(:latitude, :longitude)

      # Group to grid cells (4 decimal places ≈ 11 m) for density representation.
      buckets = pairs
        .group_by { |lat, lng| [lat.round(4), lng.round(4)] }
        .transform_values(&:count)
      max = buckets.values.max.to_f

      points = buckets.map do |(lat, lng), count|
        { lat: lat, lng: lng, count: count,
          intensity: max > 0 ? (count / max).round(4) : 0 }
      end.sort_by { |p| -p[:count] }

      render json: {
        smartProxyId: @smart_proxy.id,
        points:       points,
        totalSamples: pairs.size
      }
    end

    # ── Hotspots ──────────────────────────────────────────────────────────────

    # GET /api/smart_proxies/:id/hotspots?mode=historical|live[&start_date=&end_date=]
    # Same algorithm and output shape as Api::V1::HotspotDetectionService.
    def proxy_hotspots
      mode   = params[:mode].to_s == "live" ? :live : :historical
      result = SmartProxyHotspotService.new(
        @smart_proxy,
        mode: mode,
        from: parse_date_param(:start_date),
        to:   parse_date_param(:end_date)
      ).call

      render json: {
        smartProxyId: @smart_proxy.id,
        proxyName:    @smart_proxy.name,
        mode:         mode,
        hotspots:     result.hotspots.map { |h| serialize_hotspot(h) },
        meta: {
          totalPoints:    result.total_points,
          filteredPoints: result.filtered_points
        }
      }
    end

    private

    # ── Finders / scoping ─────────────────────────────────────────────────────

    def set_smart_proxy
      @smart_proxy = smart_proxies_scope.includes(:organization).find(params[:id])
    end

    def smart_proxies_scope
      if current_user.role == "admin"
        SmartProxy
      else
        org = current_organization
        org ? org.smart_proxies : SmartProxy.none
      end
    end

    def smart_proxy_params
      params.permit(:name, :slug, :destination_url, :active, :custom_domain)
    end

    # Returns an error string if the URL is not safe to scan, nil otherwise.
    def validate_scan_url(url)
      return "La URL debe comenzar con http:// o https://" unless url.match?(/\Ahttps?:\/\/.+/i)
      return "La URL supera el límite de 2048 caracteres" if url.length > 2048

      uri  = URI.parse(url)
      host = uri.host.to_s.downcase

      blocked_hosts = %w[localhost 127.0.0.1 ::1 0.0.0.0]
      return "No se puede escanear direcciones locales" if blocked_hosts.include?(host)

      private_ranges = [
        /\A10\.\d+\.\d+\.\d+\z/,
        /\A172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\z/,
        /\A192\.168\.\d+\.\d+\z/,
        /\A169\.254\.\d+\.\d+\z/,
        /\Afc[0-9a-f]{2}:/i,
        /\Afd[0-9a-f]{2}:/i,
      ]
      return "No se puede escanear direcciones IP privadas" if private_ranges.any? { |p| p.match?(host) }

      nil
    rescue URI::InvalidURIError
      "URL inválida"
    end

    # ── Analytics helpers ─────────────────────────────────────────────────────

    def proxy_events_scope
      scope = AnalyticsEvent.where(smart_proxy_id: @smart_proxy.id)
      from  = parse_date_param(:from)
      to    = parse_date_param(:to)
      scope = scope.where(event_date: from..) if from
      scope = scope.where(event_date: ..to)   if to
      scope
    end

    def parse_date_param(key)
      Date.parse(params[key].to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Compares active_now against the previous hour window.
    # Mirrors LiveVisitsQueryable#last_hour_delta_percent but for SmartProxyLiveVisit.
    def last_hour_delta(proxy_ids, active_now_count)
      return 0 if proxy_ids.empty?
      active_window   = SmartProxyLiveVisit::ACTIVE_WINDOW.ago
      previous_window = 1.hour.ago

      previous_count = SmartProxyLiveVisit
        .where(smart_proxy_id: proxy_ids)
        .where(last_seen_at: previous_window...active_window)
        .count

      if previous_count > 0
        ((active_now_count - previous_count) / previous_count.to_f * 100).round
      elsif active_now_count > 0
        100
      else
        0
      end
    rescue => e
      Rails.logger.error "[SMART_PROXY_LIVE_VISITS] last_hour_delta failed: #{e.message}"
      nil
    end

    # Returns the hour block with the most active sessions today.
    # Mirrors LiveVisitsQueryable#peak_today but for SmartProxyLiveVisit.
    def peak_today(proxy_ids)
      return nil if proxy_ids.empty?
      tz        = Time.zone
      now       = Time.current.in_time_zone(tz)
      today_end = now.end_of_day

      timestamps = SmartProxyLiveVisit
        .where(smart_proxy_id: proxy_ids)
        .where(last_seen_at: now.beginning_of_day..today_end)
        .pluck(:last_seen_at)

      return nil if timestamps.empty?

      counts_by_hour = timestamps
        .group_by { |ts| ts.in_time_zone(tz).beginning_of_hour }
        .transform_values(&:count)

      hour_start, count = counts_by_hour.max_by { |_, c| c }
      {
        label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
        count: count
      }
    rescue => e
      Rails.logger.error "[SMART_PROXY_LIVE_VISITS] peak_today failed: #{e.message}"
      nil
    end

    def serialize_hotspot(hotspot)
      {
        lat:          hotspot.lat,
        lng:          hotspot.lng,
        count:        hotspot.count,
        intensity:    hotspot.intensity,
        radiusMeters: hotspot.radius_meters
      }
    end
  end
end
