module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_api_credential!

      # ── Error handlers ────────────────────────────────────────────────────────

      rescue_from UncaughtThrowError do |e|
        raise e unless e.tag == :abort
        head :internal_server_error unless performed?
      end

      rescue_from ActiveRecord::RecordNotFound do
        render_error :not_found, "Resource not found"
      end

      rescue_from ActionController::ParameterMissing do |e|
        render_error :bad_request, e.message
      end

      rescue_from ActiveRecord::RecordInvalid do |e|
        render_error :unprocessable_entity, "Validation failed", details: e.record.errors.as_json
      end

      rescue_from StandardError do |e|
        Rails.logger.error "[API_V1] Unhandled error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render_error :internal_server_error, "Internal server error"
      end

      private

      # ── Authentication ────────────────────────────────────────────────────────

      def current_credential
        @current_credential
      end

      def current_organization
        @current_organization ||= current_credential&.organization
      end

      def authenticate_api_credential!
        credential = resolve_credential

        if credential.nil?
          render_error :unauthorized, "Invalid or missing API credentials"
          return
        end

        @current_credential = credential
        credential.update_column(:last_used_at, Time.current)
      end

      def resolve_credential
        key_public, key_secret = extract_key_and_secret
        return nil if key_public.blank? || key_secret.blank?

        credential = ApiCredential.find_by(key_public: key_public)
        return nil unless credential
        return nil unless credential.active?
        return nil unless credential.authenticate(key_secret)

        credential
      rescue => e
        Rails.logger.warn "[API_AUTH] Authentication error: #{e.class}: #{e.message}"
        nil
      end

      # Supports two formats:
      #   Authorization: Basic base64(key_public:key_secret)  [standard HTTP Basic]
      #   Authorization: Bearer key_public:key_secret          [simple bearer pair]
      def extract_key_and_secret
        header = request.headers["Authorization"].to_s.strip
        return [] if header.blank?

        if header.start_with?("Basic ")
          decoded = Base64.strict_decode64(header.delete_prefix("Basic ")).to_s rescue ""
          decoded.split(":", 2)
        elsif header.start_with?("Bearer ")
          header.delete_prefix("Bearer ").split(":", 2)
        else
          []
        end
      end

      # ── Scope enforcement ─────────────────────────────────────────────────────

      # Renders 403 and aborts if the current credential lacks the required scope.
      def require_scope!(scope)
        return if current_credential.scopes.include?(scope)

        render json: { error: "insufficient_scope", required: scope }, status: :forbidden
        throw :abort
      end

      # ── Response helpers ──────────────────────────────────────────────────────

      def render_error(status, message, details: nil)
        body = { error: message }
        body[:details] = details if details.present?
        render json: body, status: status
      end

      def render_ok(data, meta: nil)
        body = { data: data }
        body[:meta] = meta if meta.present?
        render json: body, status: :ok
      end

      # ── Idempotency ───────────────────────────────────────────────────────────

      # Returns the Idempotency-Key header value, or nil if absent.
      def idempotency_key_header
        request.headers["Idempotency-Key"].presence
      end

      # Looks up an existing idempotency record for the current request.
      # Returns the record if found, nil otherwise.
      def find_idempotency_record(key)
        return nil if key.blank?
        IdempotencyKey.active.find_by(
          api_credential_id: current_credential.id,
          idempotency_key:   key
        )
      end

      # Creates a locked idempotency record, claiming the slot.
      # Handles the race-condition case where two requests arrive simultaneously.
      # Returns the record on success, nil if another request already claimed it.
      def create_idempotency_lock(key, endpoint:)
        IdempotencyKey.create!(
          api_credential_id: current_credential.id,
          idempotency_key:   key,
          endpoint:          endpoint,
          expires_at:        IdempotencyKey::TTL.from_now,
          locked_at:         Time.current
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Stores the computed response on an idempotency record.
      def finalize_idempotency(record, status:, body:)
        return unless record
        record.update_columns(response_status: status, response_body: body.to_json)
      end

      # ── Scoping helpers ───────────────────────────────────────────────────────

      def organization_projects
        GeoProject.where(
          user_id: current_organization.memberships.select(:user_id)
        )
      end
    end
  end
end
