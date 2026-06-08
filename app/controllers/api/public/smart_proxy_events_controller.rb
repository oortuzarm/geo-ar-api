module Api
  module Public
    # Receives analytics events emitted by the Ubyca script injected into
    # every proxied page.  No authentication — the script runs in the end
    # user's browser.
    #
    # POST /api/public/smart_proxy_events
    #
    # For smart_proxy_heartbeat events that include lat/lng the controller
    # also upserts a SmartProxyLiveVisit record, mirroring exactly what
    # GeoPointLiveVisit does for Experiences.  This feeds live-visits,
    # hotspots, and GPS intensity with the same 45-second active window.
    class SmartProxyEventsController < ApplicationController
      # Allow calls from any origin: the script runs inside the proxied page
      # which may be on a custom domain (future feature).
      before_action :set_cors_wildcard

      ALLOWED_EVENT_TYPES = AnalyticsEvent::SMART_PROXY_EVENT_TYPES.freeze
      private_constant :ALLOWED_EVENT_TYPES

      def create
        smart_proxy = SmartProxy.find_by(id: params[:smart_proxy_id], active: true)
        return head :not_found unless smart_proxy

        event_type = params[:event_type].to_s
        return head :unprocessable_entity unless ALLOWED_EVENT_TYPES.include?(event_type)

        session_id = params[:session_id].presence || SecureRandom.uuid
        lat        = numeric_param(:latitude)
        lng        = numeric_param(:longitude)
        accuracy   = numeric_param(:accuracy)

        record_analytics_event(smart_proxy, event_type, session_id, lat, lng)

        # Mirror the GeoPointLiveVisit upsert strategy: heartbeats with GPS
        # coordinates update the live presence record so the active-window
        # (45 s) stays current.  Without lat/lng the heartbeat still records
        # the analytics event but skips the live-visit upsert.
        if event_type == "smart_proxy_heartbeat" && lat && lng
          upsert_live_visit(smart_proxy, session_id, lat, lng, accuracy)
        end

        head :no_content
      rescue => e
        Rails.logger.error "[SMART_PROXY_EVENT] #{e.class}: #{e.message}"
        head :no_content
      end

      private

      def set_cors_wildcard
        response.headers["Access-Control-Allow-Origin"]  = "*"
        response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type"
      end

      def record_analytics_event(smart_proxy, event_type, session_id, lat, lng)
        AnalyticsEvent.create!(
          smart_proxy_id:   smart_proxy.id,
          geo_project_id:   nil,
          event_type:       event_type,
          session_id:       session_id,
          event_date:       Date.current,
          source:           "smart_proxy",
          latitude:         lat,
          longitude:        lng,
          context_metadata: build_metadata(smart_proxy)
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "[SMART_PROXY_EVENT] record invalid: #{e.message}"
      end

      # Upsert pattern identical to GeoPointLiveVisit upsert in LiveVisitsController.
      # One row per (smart_proxy, session) — last_seen_at is refreshed on every
      # heartbeat so the 45-second active window stays current.
      def upsert_live_visit(smart_proxy, session_id, lat, lng, accuracy)
        visit = SmartProxyLiveVisit.find_or_initialize_by(
          smart_proxy_id: smart_proxy.id,
          session_id:     session_id
        )
        visit.assign_attributes(
          lat:          lat,
          lng:          lng,
          accuracy:     accuracy,
          last_seen_at: Time.current
        )
        visit.save!
      rescue => e
        Rails.logger.error "[SMART_PROXY_LIVE_VISIT] upsert failed: #{e.message}"
      end

      def numeric_param(key)
        v = params[key]
        return nil if v.blank?
        Float(v)
      rescue ArgumentError, TypeError
        nil
      end

      def build_metadata(smart_proxy)
        {
          smart_proxy_id:   smart_proxy.id,
          smart_proxy_slug: smart_proxy.slug,
          organization_id:  smart_proxy.organization_id,
          org_slug:         smart_proxy.organization.slug,
          host:             params[:host],
          tag:              params[:tag],
          href:             params[:href]&.slice(0, 2048),
          text:             params[:text]&.slice(0, 200),
          dwell_seconds:    params[:dwell_seconds]&.to_i
        }.compact
      end
    end
  end
end
