module Api
  module V1
    # Orchestrates presence validation for POST /api/v1/presence/validate and /check.
    #
    # All geospatial computation is delegated to GeoEngine.
    # All event and live-visit writes are done here — never in the controller.
    # Returns a Result struct; the controller owns serialization.
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
        checks = {}

        # ── Step 1: Location active ────────────────────────────────────────
        checks[:location_active] = @location.active
        return failure(checks, "location_inactive") unless @location.active

        # ── Step 2: Boundary ───────────────────────────────────────────────
        dist   = GeoEngine.distance_to(@location, @lat, @lng)
        inside = GeoEngine.inside_boundary?(@location, @lat, @lng)

        checks[:inside_boundary] = inside
        checks[:boundary_type]   = @location.activation_mode
        checks[:distance_meters] = dist.round(2) if @location.activation_mode == "radius"

        return failure(checks, "outside_boundary") unless inside

        # ── Step 3: Schedule ───────────────────────────────────────────────
        sched_ok = GeoEngine.schedule_active?(@location, at: @at)
        checks[:schedule_active] = sched_ok
        return failure(checks, "outside_schedule") unless sched_ok

        # ── Step 4: Quota (evaluate, not consume yet) ──────────────────────
        checks[:quota_available] = GeoEngine.quota_available?(@location)
        checks[:quota_remaining] = GeoEngine.quota_remaining(@location)
        return failure(checks, "quota_exhausted") unless checks[:quota_available]

        # ── Step 5: Live visits minimum ────────────────────────────────────────
        checks[:live_visits_enabled] = GeoEngine.live_visits_enabled?(@location)
        if checks[:live_visits_enabled]
          current_count = GeoEngine.live_visits_count(@location)
          minimum       = GeoEngine.live_visits_minimum(@location)
          checks[:live_visits_required] = minimum
          checks[:live_visits_current]  = current_count
          checks[:live_visits_met]      = (current_count + 1) >= minimum
          unless checks[:live_visits_met]
            @live_visits_metadata = { current_live_visits: current_count, required_live_visits: minimum }
            return failure(checks, "minimum_live_visits_not_reached")
          end
        else
          checks[:live_visits_met] = true
        end

        # ── Step 6: Dwell ──────────────────────────────────────────────────
        checks[:dwell_required] = @location.requires_dwell_time

        if @location.requires_dwell_time
          if @dwell_elapsed_seconds.nil?
            checks[:dwell_time_met] = false
            return failure(checks, "dwell_required")
          elsif @dwell_elapsed_seconds.to_i < @location.dwell_time_seconds
            checks[:dwell_time_met] = false
            return failure(checks, "dwell_time_not_met")
          else
            checks[:dwell_time_met] = true
          end
        else
          checks[:dwell_time_met] = true
        end

        # ── All checks passed ──────────────────────────────────────────────
        destination = resolve_destination(@location)
        event_id    = nil

        unless @dry_run
          # Consume quota atomically (only when all validations pass).
          if GeoEngine.quota_active?(@location)
            unless GeoEngine.consume_quota!(@location)
              # Rare race condition: quota exhausted between evaluation and consumption.
              checks[:quota_available] = false
              checks[:quota_remaining] = 0
              return failure(checks, "quota_exhausted")
            end
            # Refresh remaining after consumption.
            checks[:quota_remaining] = GeoEngine.quota_remaining(@location)
          end

          event_id = record_events(success: true, destination: destination)
          update_live_visit
        end

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

      # ── Failure path ───────────────────────────────────────────────────────

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

      # ── Event recording ────────────────────────────────────────────────────

      # Writes analytics events for the validation result.
      # Returns the ID of the primary presence.validated event.
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
          AnalyticsEvent.create!(
            base_attrs.merge(event_type: "destination.delivered")
          )
        end

        geocode_async(primary) if primary.latitude && primary.longitude

        primary.id
      rescue => e
        Rails.logger.error "[PRESENCE_VALIDATION] Event creation failed: #{e.class}: #{e.message}"
        nil
      end

      # ── Live visit ─────────────────────────────────────────────────────────

      def update_live_visit
        visit = GeoPointLiveVisit.find_or_initialize_by(
          geo_point_id: @location.id,
          session_id:   @session_id
        )
        visit.assign_attributes(
          geo_project_id: @location.geo_project_id,
          lat:            @lat,
          lng:            @lng,
          inside_radius:  true,
          last_seen_at:   Time.current
        )
        visit.save!
      rescue => e
        Rails.logger.warn "[PRESENCE_VALIDATION] Live visit update failed: #{e.class}: #{e.message}"
      end

      # ── Destination ────────────────────────────────────────────────────────

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

      # ── Async geocoding ────────────────────────────────────────────────────

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
