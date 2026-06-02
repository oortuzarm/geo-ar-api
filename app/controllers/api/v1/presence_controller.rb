module Api
  module V1
    class PresenceController < BaseController
      before_action -> { require_scope!("presence:validate") }, only: %i[validate]
      before_action -> { require_scope!("presence:check") },    only: %i[check]

      # POST /api/v1/presence/validate
      # Full validation with side effects: consumes quota, records events, updates live visits.
      def validate
        payload = parse_payload
        return if performed?  # 422 already rendered

        location = load_location(payload[:location_id])
        return if performed?  # 404 already rendered

        # ── Idempotency ──────────────────────────────────────────────────────
        idem_key = idempotency_key_header

        if idem_key.present?
          existing = find_idempotency_record(idem_key)
          if existing&.complete?
            return render json: JSON.parse(existing.response_body), status: existing.response_status
          elsif existing&.in_flight?
            return render json: { error: "Request in progress", retryAfter: 30 }, status: :conflict
          end
        end

        idem_record = idem_key.present? ? create_idempotency_lock(idem_key, endpoint: "presence:validate") : nil

        # ── Run validation ───────────────────────────────────────────────────
        result = Api::V1::PresenceValidationService.new(
          location:              location,
          lat:                   payload[:lat],
          lng:                   payload[:lng],
          session_id:            payload[:session_id],
          dwell_elapsed_seconds: payload[:dwell_elapsed_seconds],
          at:                    payload[:at],
          context:               payload[:context],
          credential:            current_credential,
          dry_run:               false
        ).call

        # ── Build and store response ─────────────────────────────────────────
        body = serialize(result)
        finalize_idempotency(idem_record, status: 200, body: body)

        render json: body
      end

      # POST /api/v1/presence/check
      # Dry-run validation — no side effects whatsoever.
      def check
        payload = parse_payload
        return if performed?

        location = load_location(payload[:location_id])
        return if performed?

        result = Api::V1::PresenceValidationService.new(
          location:              location,
          lat:                   payload[:lat],
          lng:                   payload[:lng],
          session_id:            payload[:session_id],
          dwell_elapsed_seconds: payload[:dwell_elapsed_seconds],
          at:                    payload[:at],
          context:               payload[:context],
          credential:            current_credential,
          dry_run:               true
        ).call

        render json: serialize(result)
      end

      private

      # ── Payload parsing & validation ─────────────────────────────────────────

      def parse_payload
        errors = {}

        location_id = params[:location_id].presence
        errors[:location_id] = "is required" if location_id.blank?

        session_id = params[:session_id].presence
        errors[:session_id] = "is required" if session_id.blank?

        coords = params[:coordinates] || {}
        lat_raw = coords[:latitude]
        lng_raw = coords[:longitude]
        acc_raw = coords[:accuracy_meters]

        if lat_raw.blank?
          errors[:latitude] = "is required"
        elsif !numeric?(lat_raw)
          errors[:latitude] = "must be a number"
        elsif lat_raw.to_f < -90 || lat_raw.to_f > 90
          errors[:latitude] = "must be between -90 and 90"
        end

        if lng_raw.blank?
          errors[:longitude] = "is required"
        elsif !numeric?(lng_raw)
          errors[:longitude] = "must be a number"
        elsif lng_raw.to_f < -180 || lng_raw.to_f > 180
          errors[:longitude] = "must be between -180 and 180"
        end

        if acc_raw.present? && (!numeric?(acc_raw) || acc_raw.to_f < 0)
          errors[:accuracy_meters] = "must be a positive number"
        end

        context = params[:context]
        if context.present? && !context.is_a?(ActionController::Parameters) && !context.is_a?(Hash)
          errors[:context] = "must be an object"
        end

        metadata = context.is_a?(ActionController::Parameters) ? context[:metadata] : context&.dig(:metadata)
        if metadata.present? && !metadata.is_a?(ActionController::Parameters) && !metadata.is_a?(Hash)
          errors[:metadata] = "must be an object"
        end

        unless errors.empty?
          render json: { error: "Invalid request parameters", details: errors }, status: :unprocessable_entity
          return nil
        end

        at = if params[:timestamp].present?
          Time.iso8601(params[:timestamp]) rescue Time.current
        else
          Time.current
        end

        context_hash = {}
        if context.present?
          c = context.respond_to?(:to_unsafe_h) ? context.to_unsafe_h.symbolize_keys : context.symbolize_keys
          context_hash = {
            user_ref: c[:user_ref].presence,
            metadata: c[:metadata].respond_to?(:to_unsafe_h) ? c[:metadata].to_unsafe_h : c[:metadata]
          }
        end

        {
          location_id:            location_id,
          session_id:             session_id,
          lat:                    lat_raw.to_f,
          lng:                    lng_raw.to_f,
          dwell_elapsed_seconds:  params[:dwell_elapsed_seconds].presence&.to_i,
          at:                     at,
          context:                context_hash
        }
      end

      def load_location(location_id)
        GeoPoint.joins(:geo_project)
          .where(geo_projects: { user_id: current_organization.memberships.select(:user_id) })
          .find(location_id)
      rescue ActiveRecord::RecordNotFound
        render_error :not_found, "Location not found"
        nil
      end

      # ── Response serialization ────────────────────────────────────────────────

      def serialize(result)
        {
          valid:         result.valid,
          locationId:    result.location_id,
          sessionId:     result.session_id,
          checks:        camelize_checks(result.checks),
          destination:   result.destination,
          failureReason: result.failure_reason,
          eventId:       result.event_id
        }
      end

      def camelize_checks(checks)
        return {} unless checks.is_a?(Hash)
        checks.transform_keys { |k| k.to_s.camelize(:lower).to_sym }
      end

      def numeric?(value)
        Float(value)
        true
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
