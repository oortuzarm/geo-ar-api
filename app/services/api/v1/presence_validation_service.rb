module Api
  module V1
    # Orchestrates presence validation for POST /api/v1/presence/validate and /check.
    #
    # Availability evaluation is fully delegated to GeoPointAvailabilityChecker.
    # This service owns only API v1-specific concerns:
    #   - analytics event recording (presence.validated, destination.delivered)
    #   - destination resolution from content_type/content_data
    #   - async geocoding
    #   - response serialisation (checks hash, Result struct)
    #   - dry_run forwarding
    class PresenceValidationService
      Result = Struct.new(
        :valid,
        :location_id,
        :session_id,
        :checks,
        :destination,
        :failure_reason,
        :event_id,
        keyword_init: true
      )

      # @param location [GeoPoint]
      # @param lat [Float]
      # @param lng [Float]
      # @param session_id [String]
      # @param dwell_elapsed_seconds [Integer, nil]
      # @param at [Time] — effective time for schedule checks
      # @param context [Hash] — { user_ref:, metadata: }
      # @param credential [ApiCredential]
      # @param dry_run [Boolean] — true for /check (no side effects)
      def initialize(location:, lat:, lng:, session_id:,
                     dwell_elapsed_seconds: nil, at: Time.current,
                     context: {}, credential:, dry_run: false)
        @location              = location
        @lat                   = lat.to_f
        @lng                   = lng.to_f
        @session_id            = session_id
        @dwell_elapsed_seconds = dwell_elapsed_seconds
        @at                    = at
        @context               = context || {}
        @credential            = credential
        @dry_run               = dry_run
        @live_visits_metadata  = {}
      end

      def call
        checked = GeoPointAvailabilityChecker.new(
          geo_point:             @location,
          lat:                   @lat,
          lng:                   @lng,
          session_id:            @session_id,
          dwell_elapsed_seconds: @dwell_elapsed_seconds,
          at:                    @at,
          dry_run:               @dry_run
        ).call

        checks = checked.checks

        unless checked.passed
          # Carry live-visits counts into analytics context_metadata when relevant.
          @live_visits_metadata = checked.reason == "minimum_live_visits_not_reached" ?
                                    checked.availability : {}
          return failure(checks, checked.reason)
        end

        # All checks passed (checker already consumed quota + upserted live_visit).
        destination = resolve_destination(@location)
        event_id    = nil
        event_id    = record_events(success: true, destination: destination) unless @dry_run

        Result.new(
          valid:          true,
          location_id:    @location.id,
          session_id:     @session_id,
          checks:         checks,
          destination:    destination,
          failure_reason: nil,
          event_id:       event_id
        )
      end

      private

      # ── Failure path ──────────────────────────────────────────────────────────

      def failure(checks, reason)
        event_id = nil
        event_id = record_events(success: false, failure_reason: reason) unless @dry_run

        Result.new(
          valid:          false,
          location_id:    @location.id,
          session_id:     @session_id,
          checks:         checks,
          destination:    nil,
          failure_reason: reason,
          event_id:       event_id
        )
      end

      # ── Event recording ───────────────────────────────────────────────────────

      def record_events(success:, destination: nil, failure_reason: nil)
        merged_metadata = (@context[:metadata].presence || {}).merge(@live_visits_metadata).presence

        base_attrs = {
          geo_project_id:    @location.geo_project_id,
          geo_point_id:      @location.id,
          session_id:        @session_id,
          event_date:        Date.current,
          latitude:          @lat,
          longitude:         @lng,
          source:            "api",
          api_credential_id: @credential.id,
          user_ref:          @context[:user_ref],
          context_metadata:  merged_metadata
        }

        primary = AnalyticsEvent.create!(
          base_attrs.merge(
            event_type:    "presence.validated",
            failure_reason: failure_reason
          )
        )

        if success && destination
          AnalyticsEvent.create!(base_attrs.merge(event_type: "destination.delivered"))
        end

        geocode_async(primary) if primary.latitude && primary.longitude

        primary.id
      rescue => e
        Rails.logger.error "[PRESENCE_VALIDATION] Event creation failed: #{e.class}: #{e.message}"
        nil
      end

      # ── Destination ───────────────────────────────────────────────────────────

      def resolve_destination(location)
        cd  = location.content_data
        url = case location.content_type
              when "url"
                (cd.is_a?(Hash) && cd["url"].present?) ? cd["url"] : location.lookiar_url.presence
              when "video", "audio", "file"
                cd.is_a?(Hash) ? cd["file_url"].presence : nil
              else
                location.lookiar_url.presence
              end

        url ? { type: "url", url: url } : nil
      end

      # ── Async geocoding ───────────────────────────────────────────────────────

      def geocode_async(event)
        event_id = event.id
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            geo = NominatimGeocoder.reverse(event.latitude, event.longitude)
            if geo
              AnalyticsEvent.where(id: event_id).update_all(
                country: geo[:country],
                city:    geo[:city],
                commune: geo[:commune]
              )
            end
          end
        rescue => e
          Rails.logger.error "[geocode_async] #{e.class}: #{e.message}"
        end
      end
    end
  end
end
