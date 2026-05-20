module Api
  class TemporaryPreviewsController < ApplicationController
    # create and show are public; claim requires authentication.
    skip_before_action :authenticate_user!, except: %i[claim], raise: false
    before_action :authenticate_user!, only: %i[claim]

    # Temporary previews must never be cached — they change state (claim → 410).
    before_action :prevent_caching

    # NOTE: inline cleanup was removed from before_action.
    # Cleanup runs only via: rake temporary_previews:cleanup (or a future cron job).
    # Running cleanup synchronously on user requests caused 408 timeouts when
    # blob deletion made external HTTP calls to Vercel inside the request lifecycle.

    # POST /api/temporary_previews
    # Receives the demo project state from /try and persists it for 30 minutes.
    def create
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      points = Array(params[:points])
      log_create_request(points)

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

      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      payload       = build_payload(params[:project], points)
      payload_bytes = payload.to_json.bytesize

      t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "[PREVIEW_CREATE] payload_bytes=#{payload_bytes} build_ms=#{((t2 - t1) * 1000).round(1)}"

      if payload_bytes > TemporaryPreview::MAX_PAYLOAD_BYTES
        render json: { error: "El payload es demasiado grande." }, status: :unprocessable_entity
        return
      end

      preview = TemporaryPreview.create!(payload: payload)

      t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "[PREVIEW_CREATE] done token=#{preview.token[0, 8]}… " \
        "validate_ms=#{((t1 - t0) * 1000).round(1)} " \
        "build_ms=#{((t2 - t1) * 1000).round(1)} " \
        "db_ms=#{((t3 - t2) * 1000).round(1)} " \
        "total_ms=#{((t3 - t0) * 1000).round(1)}"

      render json: preview_created_json(preview), status: :created

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "[PREVIEW_CREATE] RecordInvalid — #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "[PREVIEW_CREATE] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render json: { error: "Error al crear preview: #{e.message}" }, status: :unprocessable_entity
    end

    # GET /api/temporary_previews/:token
    # Returns the stored payload if still active.
    # 410 if claimed, 410 if expired, 404 if absent.
    def show
      tok_short = params[:token].to_s[0, 8]
      has_col   = TemporaryPreview.column_names.include?("claimed_at")
      Rails.logger.info "[TEMP_PREVIEW] show start token=#{tok_short}… has_claimed_at_col=#{has_col}"

      preview = TemporaryPreview.find_by!(token: params[:token])

      claimed_at_val = has_col ? preview.read_attribute(:claimed_at).inspect : "col_missing"
      Rails.logger.info "[TEMP_PREVIEW] show found preview=#{preview.id} " \
        "claimed_at=#{claimed_at_val} claimed?=#{preview.claimed?} expired?=#{preview.expired?}"

      if preview.claimed?
        Rails.logger.info "[TEMP_PREVIEW] show → 410 claimed"
        render json: { error: "Esta previsualización ya no está disponible." }, status: :gone
        return
      end

      if preview.expired?
        Rails.logger.info "[TEMP_PREVIEW] show → 410 expired"
        render json: { error: "Esta previsualización ya no está disponible." }, status: :gone
        return
      end

      Rails.logger.info "[TEMP_PREVIEW] show → 200 ok"
      render json: preview_show_json(preview)
    end

    # POST /api/temporary_previews/:token/claim
    # Authenticated. Converts the preview into a real GeoProject owned by current_user.
    # Idempotency: the preview is destroyed after a successful claim; a second call gets 404.
    # Race conditions: with_lock (SELECT FOR UPDATE) prevents double-processing.
    #
    # Optional body param: planKey (converted to plan_key by normalize_params).
    # If present, assigns the plan to the user using the same plan_id field that admin uses.
    # TODO(Paddle): once checkout is integrated, verify payment before assigning the plan.
    def claim
      tok_short = params[:token].to_s[0, 8]
      has_col   = TemporaryPreview.column_names.include?("claimed_at")
      Rails.logger.info "[TEMP_PREVIEW] claim start token=#{tok_short}… has_claimed_at_col=#{has_col}"

      preview = TemporaryPreview.find_by!(token: params[:token])

      claimed_at_before = has_col ? preview.read_attribute(:claimed_at).inspect : "col_missing"
      Rails.logger.info "[TEMP_PREVIEW] claim found preview=#{preview.id} " \
        "claimed_at_before=#{claimed_at_before} claimed?=#{preview.claimed?} expired?=#{preview.expired?}"

      if preview.claimed?
        Rails.logger.info "[TEMP_PREVIEW] claim → 410 pre-lock already claimed"
        render json: { error: "Esta previsualización ya no está disponible." }, status: :gone
        return
      end

      if preview.expired?
        Rails.logger.info "[TEMP_PREVIEW] claim → 410 expired"
        render json: { error: "Este preview ha expirado." }, status: :gone
        return
      end

      # ── Plan resolution (pre-Paddle: assigns plan without verifying payment) ──
      # normalize_params converts incoming camelCase planKey → plan_key.
      plan = nil
      if params[:plan_key].present?
        plan = resolve_plan(params[:plan_key])
        if plan.nil?
          render json: { error: "Plan '#{params[:plan_key]}' no encontrado." }, status: :unprocessable_entity
          return
        end
      end

      Rails.logger.info "[TEMP_PREVIEW] claim plan=#{plan&.slug.inspect} pts=#{(preview.payload["points"] || []).size}"

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
      # with_lock reloads the row with SELECT FOR UPDATE, so preview reflects the
      # latest DB state at lock time. already_claimed handles the race where two
      # simultaneous requests both pass the pre-lock check but only the first
      # should create the project.
      project         = nil
      already_claimed = false

      Rails.logger.info "[TEMP_PREVIEW] claim entering with_lock preview=#{preview.id}"

      preview.with_lock do
        # Re-check after acquiring the lock — another request may have claimed
        # this preview between our pre-lock check and now.
        if preview.claimed?
          Rails.logger.info "[TEMP_PREVIEW] claim inside lock: already_claimed → skip"
          already_claimed = true
          next
        end

        Rails.logger.info "[TEMP_PREVIEW] claim inside lock: not claimed, proceeding"

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

        Rails.logger.info "[TEMP_PREVIEW] claim inside lock: project created project=#{project.id} pts=#{points_data.size}"

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

        Rails.logger.info "[TEMP_PREVIEW] claim inside lock: #{points_data.size} geo_point(s) created"

        # ── Plan assignment (same field admin uses; no payment activation yet) ──
        # TODO(Paddle): before updating plan_id here, verify the Paddle checkout
        # session or subscription is valid and paid.
        if plan
          plan_attrs = { plan_id: plan.id }
          if plan.has_trial && plan.trial_days.to_i > 0
            now = Time.current
            plan_attrs[:subscription_status] = "trial"
            plan_attrs[:trial_starts_at]     = now
            plan_attrs[:trial_ends_at]       = now + plan.trial_days.days
          else
            plan_attrs[:subscription_status] = "active"
          end
          current_user.update!(plan_attrs)
          Rails.logger.info "[TEMP_PREVIEW] claim inside lock: user plan updated plan=#{plan.slug} status=#{plan_attrs[:subscription_status]}"
        end

        # Soft-invalidate the preview. Keeps the row so GET /temporary/:token
        # can return 410 "already claimed" instead of a generic 404.
        # Payload is cleared to avoid retaining user data beyond claim time.
        Rails.logger.info "[TEMP_PREVIEW] claim inside lock: about to update preview claimed_at has_col=#{has_col}"
        preview.update!(claimed_at: Time.current, payload: {})

        claimed_at_after = has_col ? preview.read_attribute(:claimed_at).inspect : "col_missing"
        Rails.logger.info "[TEMP_PREVIEW] claim inside lock: preview updated claimed_at_after=#{claimed_at_after}"
      end

      Rails.logger.info "[TEMP_PREVIEW] claim with_lock committed already_claimed=#{already_claimed}"

      if already_claimed
        Rails.logger.info "[TEMP_PREVIEW] claim → 410 post-lock already claimed"
        render json: { error: "Esta previsualización ya no está disponible." }, status: :gone
        return
      end

      Rails.logger.info "[TEMP_PREVIEW] claim → 201 success project=#{project&.id}"

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
      return false unless f >= min && f <= max
      # JSON-parsed numbers (Float/Integer) are already trusted; string inputs
      # get a format check to reject non-numeric values.
      return true if value.is_a?(Numeric)
      value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
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
        id:                SecureRandom.uuid,
        name:              p[:name].to_s.strip,
        latitude:          p[:latitude].to_f,
        longitude:         p[:longitude].to_f,
        activation_radius: (p[:activation_radius] || 50).to_i,
        content_type:      p[:content_type].presence || "url",
        # safe_hash converts ActionController::Parameters → plain Hash so the
        # JSONB serializer never encounters unpermitted params in the payload.
        content_data:      safe_hash(p[:content_data]),
        lookiar_url:       p[:lookiar_url].to_s,
        image:             p[:image],
        description:       p[:description].to_s,
        instructions:      p[:instructions].to_s,
        button_text:       p[:button_text].to_s,
        active:            p.fetch(:active, true),
        order:             (p[:order] || 0).to_i,
        availability:      safe_hash(p[:availability]) || {}
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

    def resolve_plan(slug)
      Plan.find_by(slug: slug)
    end

    # Converts ActionController::Parameters or Hash → plain Hash; nil-safe.
    # to_unsafe_h recursively converts all nested params, returning a
    # HashWithIndifferentAccess (a Hash subclass) that is safe for JSONB storage.
    def safe_hash(value)
      return nil if value.nil?
      value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
    end

    def log_create_request(points)
      pt0 = points.first
      Rails.logger.info(
        "[PREVIEW_CREATE] points=#{points.size} " \
        "project_keys=#{params[:project]&.keys&.join(',')} " \
        "pt0_keys=#{pt0&.keys&.join(',')} " \
        "pt0_content_type=#{pt0&.dig(:content_type).inspect} " \
        "pt0_content_data_class=#{pt0&.dig(:content_data).class} " \
        "pt0_content_data_keys=#{pt0&.dig(:content_data).respond_to?(:keys) ? pt0.dig(:content_data).keys.join(',') : 'n/a'} " \
        "pt0_lookiar_url=#{pt0&.dig(:lookiar_url).inspect} " \
        "pt0_availability_class=#{pt0&.dig(:availability).class} " \
        "pt0_image_present=#{pt0&.dig(:image).present?}"
      )
    end

    # Instructs browsers and proxies never to store or reuse preview responses.
    # Without this, a cached 200 would survive the claim and keep returning 304.
    def prevent_caching
      response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
      response.headers["Pragma"]        = "no-cache"
      response.headers["Expires"]       = "0"
    end

  end
end
