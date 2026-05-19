module Api
  class TemporaryPreviewsController < ApplicationController
    # No authentication — /try is a public, unauthenticated flow.
    skip_before_action :authenticate_user!, raise: false

    # Best-effort inline cleanup on every create and show request (throttled to once per 10 min).
    before_action :trigger_inline_cleanup

    # POST /api/temporary_previews
    # Receives the demo project state from /try and persists it for 30 minutes.
    def create
      points = Array(params[:points])

      if points.empty?
        render json: { error: "Se requiere al menos una ubicación." }, status: :unprocessable_entity
        return
      end

      if points.size > TemporaryPreview::MAX_POINTS
        render json: {
          error: "El preview no puede tener más de #{TemporaryPreview::MAX_POINTS} ubicaciones."
        }, status: :unprocessable_entity
        return
      end

      unless valid_points?(points)
        render json: {
          error: "Cada ubicación debe tener nombre, latitud y longitud válidos."
        }, status: :unprocessable_entity
        return
      end

      payload = build_payload(params[:project], points)

      if payload.to_json.bytesize > TemporaryPreview::MAX_PAYLOAD_BYTES
        render json: { error: "El payload es demasiado grande." }, status: :unprocessable_entity
        return
      end

      preview = TemporaryPreview.create!(payload: payload)

      render json: preview_created_json(preview), status: :created
    end

    # GET /api/temporary_previews/:token
    # Returns the stored payload if not expired, 410 if expired, 404 if absent.
    def show
      preview = TemporaryPreview.find_by!(token: params[:token])

      if preview.expired?
        render json: { error: "Este preview ha expirado." }, status: :gone
        return
      end

      render json: preview_show_json(preview)
    end

    private

    # ── Validation ─────────────────────────────────────────────────────────────

    def valid_points?(points)
      points.all? do |p|
        p[:name].present? &&
          valid_coordinate?(p[:latitude],  -90,  90) &&
          valid_coordinate?(p[:longitude], -180, 180)
      end
    end

    def valid_coordinate?(value, min, max)
      return false if value.nil?
      f = value.to_f
      f >= min && f <= max && value.to_s =~ /\A-?\d+(\.\d+)?\z/
    end

    # ── Payload construction ────────────────────────────────────────────────────

    # Stores snake_case keys (normalize_params already converted camelCase input).
    # Deep camelize is applied on the way out so the frontend always gets camelCase.
    def build_payload(project_params, points_params)
      {
        project: extract_project(project_params),
        points:  points_params.map { |p| extract_point(p) }
      }
    end

    def extract_project(p)
      return {} if p.blank?
      {
        title:                    p[:title].to_s.strip,
        subtitle:                 p[:subtitle].to_s,
        description:              p[:description].to_s,
        cover_image:              p[:cover_image],
        how_to_get:               p[:how_to_get].to_s,
        share_text:               p[:share_text].to_s,
        public_initial_view_mode: p[:public_initial_view_mode].presence || "fit_points",
        public_initial_center_lat: p[:public_initial_center_lat],
        public_initial_center_lng: p[:public_initial_center_lng],
        public_initial_zoom:       p[:public_initial_zoom]
      }
    end

    def extract_point(p)
      {
        id:               SecureRandom.uuid,
        name:             p[:name].to_s.strip,
        latitude:         p[:latitude].to_f,
        longitude:        p[:longitude].to_f,
        activation_radius: (p[:activation_radius] || 50).to_i,
        content_type:     p[:content_type].presence || "url",
        content_data:     p[:content_data],
        image:            p[:image],
        description:      p[:description].to_s,
        instructions:     p[:instructions].to_s,
        button_text:      p[:button_text].to_s,
        active:           p.fetch(:active, true),
        order:            (p[:order] || 0).to_i,
        availability:     p[:availability] || {}
      }
    end

    # ── JSON responses ──────────────────────────────────────────────────────────

    def preview_created_json(preview)
      base = ENV.fetch("APP_BASE_URL", "https://studio.ubyca.com")
      {
        token:     preview.token,
        publicUrl: "#{base}/temporary/#{preview.token}",
        expiresAt: preview.expires_at.iso8601(3)
      }
    end

    def preview_show_json(preview)
      raw = preview.payload
      {
        token:     preview.token,
        expiresAt: preview.expires_at.iso8601(3),
        project:   deep_camelize(raw["project"] || {}),
        geoPoints: (raw["points"] || []).map { |p| deep_camelize(p) }
      }
    end

    # Recursively converts snake_case hash keys to camelCase for the JS frontend.
    def deep_camelize(obj)
      case obj
      when Hash
        obj.transform_keys { |k| k.to_s.camelize(:lower) }
           .transform_values { |v| deep_camelize(v) }
      when Array
        obj.map { |v| deep_camelize(v) }
      else
        obj
      end
    end

    # Fires best-effort, throttled cleanup — never raises or blocks the response.
    def trigger_inline_cleanup
      TemporaryPreviewsCleanupService.run_inline
    rescue => e
      Rails.logger.warn "[PREVIEW_CLEANUP] before_action rescue — #{e.message}"
    end
  end
end
