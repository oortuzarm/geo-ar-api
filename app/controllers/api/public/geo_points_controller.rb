module Api
  module Public
    class GeoPointsController < ApplicationController
      before_action :set_project
      before_action :set_point, only: %i[access complete_dwell]

      # GET /api/public/geo_projects/:geo_project_id/geo_points
      def index
        points = @project.geo_points
                         .where(active: true)
                         .includes(:geo_point_collections)
                         .order(:order)
        render json: points.map(&:as_public_api_json)
      end

      # GET /api/public/geo_projects/:geo_project_id/geo_points/session_visited_points?session_id=...
      # Returns the IDs of all active points in this project that the given session has visited
      # (has a radius_enter analytics event for).
      def session_visited_points
        session_id = params[:session_id].presence
        unless session_id
          return render json: { visited_point_ids: [] }
        end

        point_ids = @project.geo_points.where(active: true).pluck(:id)
        visited = AnalyticsEvent
          .where(session_id: session_id, geo_point_id: point_ids, event_type: "radius_enter")
          .distinct
          .pluck(:geo_point_id)
          .map(&:to_s)

        render json: { visited_point_ids: visited }
      end

      # POST /api/public/geo_projects/:geo_project_id/geo_points/:id/access
      # Body: { latitude:, longitude:, session_id?: String, local_day?: "Lun", local_time?: "09:30" }
      def access
        lat        = params[:latitude].to_f
        lng        = params[:longitude].to_f
        session_id = params[:session_id].presence || SecureRandom.uuid

        Rails.logger.info "[ACCESS] ── START ──────────────────────────────────────"
        Rails.logger.info "[ACCESS] project_id=#{@project.id} point_id=#{@point.id}"
        Rails.logger.info "[ACCESS] user lat=#{lat} lng=#{lng} mode=#{@point.activation_mode}"
        Rails.logger.info "[ACCESS] radius=#{@point.activation_radius}m availability=#{@point.availability.inspect}"

        # Informative points bypass all access checks — content is always available.
        if @point.point_mode == "informative"
          Rails.logger.info "[ACCESS] informative point — bypassing all checks"
          ct = @point.content_type.presence || "url"
          cd = @point.content_data.presence || {}
          case ct
          when "url"
            target_url = cd["url"].presence || @point.lookiar_url.presence
            return render json: { success: true, content_type: "url", url: target_url }
          when "video", "audio", "file"
            file_url = cd["file_url"].presence
            return render json: { success: true, content_type: ct, file_url: file_url,
                                  file_name: cd["file_name"], mime_type: cd["mime_type"] }
          else
            return render json: { success: true, content_type: "info" }
          end
        end

        dist   = GeoEngine.distance_to(@point, lat, lng)
        within = GeoEngine.inside_boundary?(@point, lat, lng)

        Rails.logger.info "[ACCESS] distance=#{dist.round(2)}m within_boundary=#{within}"

        unless within
          Rails.logger.info "[ACCESS] DENY reason=boundary dist=#{dist.round(2)}m mode=#{@point.activation_mode}"
          return render_deny("Debes estar dentro del área para acceder")
        end

        sched_ok = GeoEngine.schedule_active?(
          @point,
          local_day:  params[:local_day].presence,
          local_time: params[:local_time].presence
        )
        Rails.logger.info "[ACCESS] schedule_ok=#{sched_ok}"

        unless sched_ok
          Rails.logger.info "[ACCESS] DENY reason=schedule"
          return render_deny("Esta experiencia está fuera del horario disponible")
        end

        if GeoEngine.quota_active?(@point)
          av = @point.availability || {}
          Rails.logger.info "[ACCESS] quota active limit=#{av["quota_limit"]} used=#{av["quota_used"]}"
          unless GeoEngine.quota_available?(@point)
            Rails.logger.info "[ACCESS] DENY reason=quota exhausted"
            return render_deny("No quedan cupos disponibles")
          end
        else
          Rails.logger.info "[ACCESS] quota not active — skipping"
        end

        if GeoEngine.live_visits_enabled?(@point)
          current_count = GeoEngine.live_visits_count(@point)
          minimum       = GeoEngine.live_visits_minimum(@point)
          unless (current_count + 1) >= minimum
            Rails.logger.info "[ACCESS] DENY reason=live_visits current=#{current_count} minimum=#{minimum}"
            return render_deny("Se requiere un mínimo de #{minimum} personas en el área para acceder")
          end
          Rails.logger.info "[ACCESS] live_visits ok current=#{current_count} minimum=#{minimum}"
        end

        # ── Collection check ────────────────────────────────────────────────────
        # @point.geo_point_collections is already preloaded via set_point.
        if @point.geo_point_collections.any?
          required_ids = @point.geo_point_collections.map { |c| c.required_geo_point_id.to_s }
          visited_ids  = AnalyticsEvent
            .where(session_id: session_id, geo_point_id: required_ids, event_type: "radius_enter")
            .distinct
            .pluck(:geo_point_id)
            .map(&:to_s)
          missing = required_ids - visited_ids
          if missing.any?
            Rails.logger.info "[ACCESS] DENY reason=collection missing=#{missing}"
            return render_deny("Debes visitar todas las ubicaciones requeridas antes de acceder")
          end
          Rails.logger.info "[ACCESS] collection ok required=#{required_ids.size} visited=#{visited_ids.size}"
        end

        if GeoEngine.quota_active?(@point)
          unless GeoEngine.consume_quota!(@point)
            Rails.logger.info "[ACCESS] DENY reason=quota exhausted (race)"
            return render_deny("No quedan cupos disponibles")
          end
          Rails.logger.info "[ACCESS] quota consumed ok"
        end

        upsert_live_visit(session_id, lat, lng)

        ct = @point.content_type.presence || "url"
        cd = @point.content_data.presence || {}

        Rails.logger.info "[ACCESS] content_type=#{ct}"

        case ct
        when "url"
          target_url = cd["url"].presence || @point.lookiar_url.presence
          unless target_url
            return render json: { success: false, message: "No se encontró una URL válida para esta experiencia" },
                          status: :unprocessable_entity
          end
          render json: { success: true, content_type: "url", url: target_url }

        when "video", "audio", "file"
          file_url = cd["file_url"].presence
          unless file_url
            return render json: { success: false, message: "No se encontró un archivo para esta experiencia" },
                          status: :unprocessable_entity
          end
          render json: {
            success:      true,
            content_type: ct,
            file_url:     file_url,
            file_name:    cd["file_name"],
            mime_type:    cd["mime_type"]
          }

        else
          render_deny("Tipo de contenido no válido")
        end
      end

      # POST /api/public/geo_projects/:geo_project_id/geo_points/:id/complete_dwell
      # Body: { latitude:, longitude:, started_at: Integer (Unix seconds) }
      def complete_dwell
        unless @point.requires_dwell_time
          return render json: { unlocked: false, message: "Este punto no requiere permanencia." },
                        status: :unprocessable_entity
        end

        lat  = params[:latitude].to_f
        lng  = params[:longitude].to_f

        unless GeoEngine.inside_boundary?(@point, lat, lng)
          return render json: { unlocked: false, message: "Saliste del área antes de completar el tiempo." },
                        status: :unprocessable_entity
        end

        # started_at is required when the point has a configured dwell time.
        # Rejecting 0 / blank prevents bypassing the time check by omitting the param.
        started_at = params[:started_at].to_i
        if @point.dwell_time_seconds.to_i > 0 && started_at <= 0
          return render json: {
            unlocked: false,
            reason:   "dwell_time_required",
            message:  "Debes completar el tiempo de permanencia requerido."
          }, status: :unprocessable_entity
        end

        if started_at > 0
          elapsed = Time.current.to_i - started_at
          unless elapsed >= @point.dwell_time_seconds
            return render json: { unlocked: false, message: "El tiempo de permanencia no se completó." },
                          status: :unprocessable_entity
          end
        end

        render json: { unlocked: true }
      end

      private

      def set_project
        @project = GeoProject.find(params[:geo_project_id])
        unless @project.status == "active"
          render json: { message: "Proyecto no publicado" }, status: :forbidden
        end
      end

      def set_point
        @point = @project.geo_points
                         .includes(:geo_point_collections)
                         .find_by(id: params[:id], active: true)
        unless @point
          render json: { message: "Punto no encontrado" }, status: :not_found
        end
      end

      def render_deny(message)
        render json: { success: false, message: }, status: :unprocessable_entity
      end

      def upsert_live_visit(session_id, lat, lng)
        visit = GeoPointLiveVisit.find_or_initialize_by(
          geo_point_id: @point.id,
          session_id:   session_id
        )
        visit.assign_attributes(
          geo_project_id: @project.id,
          lat:            lat,
          lng:            lng,
          inside_radius:  true,
          last_seen_at:   Time.current
        )
        visit.save!
      rescue => e
        Rails.logger.warn "[ACCESS] Live visit upsert failed: #{e.class}: #{e.message}"
      end
    end
  end
end
