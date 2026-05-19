module Api
  class TemporaryPreviewsController < ApplicationController
    # create and show are public; claim requires authentication.
    skip_before_action :authenticate_user!, except: %i[claim], raise: false
    before_action :authenticate_user!, only: %i[claim]

    # Best-effort inline cleanup on every request (throttled to once per 10 min).
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

    # POST /api/temporary_previews/:token/claim
    # Authenticated. Converts the preview into a real GeoProject owned by current_user.
    # Idempotency: the preview is destroyed after a successful claim; a second call gets 404.
    # Race conditions: with_lock (SELECT FOR UPDATE) prevents double-processing.
    def claim
      preview = TemporaryPreview.find_by!(token: params[:token])

      if preview.expired?
        render json: { error: "Este preview ha expirado." }, status: :gone
        return
      end

      # ── Billing note ──────────────────────────────────────────────────────────
      # TODO(Paddle): cuando Paddle esté integrado, este endpoint debe validar
      # la suscripción/checkout antes de crear el proyecto real.
      # Punto de extensión sugerido: recibir plan_id o paddle_subscription_id
      # en el body y verificar contra la API de Paddle antes de proceder.
      #
      # ── Capacity guard ────────────────────────────────────────────────────────
      # Subscription-active is intentionally NOT checked here: this is the
      # first-conversion path where a brand-new user (no active subscription yet)
      # turns their demo session into a real account.
      #
      # The hard cap of MAX_POINTS was already enforced when the preview was
      # created, so raw_pts.size is guaranteed ≤ MAX_POINTS at this point.
      # We re-assert it here as a belt-and-suspenders safety guard only.
      raw_pts = preview.payload["points"] || []

      if raw_pts.size > TemporaryPreview::MAX_POINTS
        render json: {
          error: "El preview supera el límite de #{TemporaryPreview::MAX_POINTS} ubicaciones."
        }, status: :unprocessable_entity
        return
      end

      # ── Claim inside a locked transaction ─────────────────────────────────────
      # with_lock reloads the row with SELECT FOR UPDATE.
      # If a concurrent request already destroyed the preview, lock! raises
      # RecordNotFound → handled by ApplicationController rescue_from → 404.
      project = nil

      preview.with_lock do
        raw_project = preview.payload["project"] || {}
        points_data = preview.payload["points"]  || []

        project = current_user.geo_projects.create!(
          title:                     raw_project["title"].presence || "Mi experiencia",
          subtitle:                  raw_project["subtitle"].to_s,
          description:               raw_project["description"].to_s,
          cover_image:               raw_project["cover_image"],
          how_to_get:                raw_project["how_to_get"].to_s,
          share_text:                raw_project["share_text"].to_s,
          public_initial_view_mode:  raw_project["public_initial_view_mode"].presence || "fit_points",
          public_initial_center_lat: raw_project["public_initial_center_lat"],
          public_initial_center_lng: raw_project["public_initial_center_lng"],
          public_initial_zoom:       raw_project["public_initial_zoom"],
          status:                    "draft"
        )

        points_data.each_with_index do |pt, idx|
          project.geo_points.create!(
            name:              pt["name"].to_s.presence || "Punto #{idx + 1}",
            lookiar_url:       pt["lookiar_url"].to_s,
            latitude:          pt["latitude"].to_f,
            longitude:         pt["longitude"].to_f,
            activation_radius: (pt["activation_radius"] || 50).to_i,
            content_type:      pt["content_type"].presence || "url",
            content_data:      pt["content_data"] || {},
            image:             pt["image"],
            description:       pt["description"].to_s,
            instructions:      pt["instructions"].to_s,
            button_text:       pt["button_text"].to_s,
            active:            pt.fetch("active", true),
            order:             pt["order"] || idx,
            availability:      pt["availability"] || {}
          )
        end

        # Destroy the preview — it has been claimed and is no longer needed.
        preview.destroy!
      end

      base = ENV.fetch("APP_BASE_URL", "https://studio.ubyca.com")
      render json: {
        projectId:   project.id,
        redirectUrl: "#{base}/project/#{project.id}"
      }, status: :created
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
