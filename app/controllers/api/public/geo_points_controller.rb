module Api
  module Public
    class GeoPointsController < ApplicationController
      before_action :set_project
      before_action :set_point, only: %i[access complete_dwell]

      # GET /api/public/geo_projects/:geo_project_id/geo_points
      def index
        points = @project.geo_points.where(active: true).order(:order)
        render json: points.map(&:as_public_api_json)
      end

      # POST /api/public/geo_projects/:geo_project_id/geo_points/:id/access
      # Body: { latitude:, longitude:, local_day?: "Lun", local_time?: "09:30" }
      def access
        lat = params[:latitude].to_f
        lng = params[:longitude].to_f

        Rails.logger.info "[ACCESS] ── START ──────────────────────────────────────"
        Rails.logger.info "[ACCESS] project_id=#{@project.id} point_id=#{@point.id}"
        Rails.logger.info "[ACCESS] user lat=#{lat} lng=#{lng} mode=#{@point.activation_mode}"
        Rails.logger.info "[ACCESS] radius=#{@point.activation_radius}m availability=#{@point.availability.inspect}"

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
          unless GeoEngine.consume_quota!(@point)
            Rails.logger.info "[ACCESS] DENY reason=quota exhausted"
            return render_deny("No quedan cupos disponibles")
          end
          Rails.logger.info "[ACCESS] quota consumed ok"
        else
          Rails.logger.info "[ACCESS] quota not active — skipping"
        end

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
        dist = GeoEngine.distance_to(@point, lat, lng)

        # Generous tolerance (+20 m) for GPS drift at timer completion.
        unless dist <= @point.activation_radius + 20
          return render json: { unlocked: false, message: "Saliste del área antes de completar el tiempo." },
                        status: :unprocessable_entity
        end

        started_at = params[:started_at].to_i
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
        @point = @project.geo_points.find_by(id: params[:id], active: true)
        unless @point
          render json: { message: "Punto no encontrado" }, status: :not_found
        end
      end

      def render_deny(message)
        render json: { success: false, message: }, status: :unprocessable_entity
      end
    end
  end
end
