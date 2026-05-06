module Api
  module Public
    class GeoPointsController < ApplicationController
      before_action :set_project
      before_action :set_point, only: %i[access]

      # GET /api/public/geo_projects/:geo_project_id/geo_points
      # Returns active points without lookiarUrl (URL is protected).
      def index
        points = @project.geo_points.where(active: true).order(:order)
        render json: points.map(&:as_public_api_json)
      end

      # POST /api/public/geo_projects/:geo_project_id/geo_points/:id/access
      # Body: { latitude: Float, longitude: Float }
      # Validates location + schedule + quota, then returns the destination URL.
      def access
        lat = params[:latitude].to_f
        lng = params[:longitude].to_f

        Rails.logger.info "[ACCESS] ── START ──────────────────────────────────────"
        Rails.logger.info "[ACCESS] project_id=#{@project.id} point_id=#{@point.id}"
        Rails.logger.info "[ACCESS] raw params: lat_raw=#{params[:latitude].inspect} lng_raw=#{params[:longitude].inspect}"
        Rails.logger.info "[ACCESS] user   lat=#{lat} lng=#{lng}"
        Rails.logger.info "[ACCESS] point  lat=#{@point.latitude} lng=#{@point.longitude}"
        Rails.logger.info "[ACCESS] radius=#{@point.activation_radius}m"
        Rails.logger.info "[ACCESS] availability=#{@point.availability.inspect}"

        dist = haversine(lat, lng, @point.latitude, @point.longitude)
        within = dist <= @point.activation_radius

        Rails.logger.info "[ACCESS] distance=#{dist.round(2)}m within_radius=#{within}"

        unless within
          Rails.logger.info "[ACCESS] DENY reason=distance dist=#{dist.round(2)}m > radius=#{@point.activation_radius}m"
          return render_deny("Debes estar dentro del área para acceder")
        end

        sched_ok = schedule_ok?
        Rails.logger.info "[ACCESS] schedule_ok=#{sched_ok}"

        unless sched_ok
          Rails.logger.info "[ACCESS] DENY reason=schedule availability=#{@point.availability.inspect}"
          return render_deny("Esta experiencia está fuera del horario disponible")
        end

        if quota_active?
          av    = @point.availability || {}
          Rails.logger.info "[ACCESS] quota active limit=#{av["quota_limit"]} used=#{av["quota_used"]}"
          msg = try_decrement_quota
          if msg
            Rails.logger.info "[ACCESS] DENY reason=quota msg=#{msg}"
            return render_deny(msg)
          end
          Rails.logger.info "[ACCESS] quota decremented ok"
        else
          Rails.logger.info "[ACCESS] quota not active — skipping"
        end

        target_url = @point.lookiar_url.presence
        Rails.logger.info "[ACCESS] target_url=#{target_url.inspect}"

        unless target_url
          Rails.logger.info "[ACCESS] DENY reason=empty_url point_id=#{@point.id}"
          return render json: { success: false, message: "No se encontró una URL válida para esta experiencia" }, status: :unprocessable_entity
        end

        Rails.logger.info "[ACCESS] success response url=#{target_url}"
        render json: { success: true, url: target_url }
      end

      private

      def set_project
        @project = GeoProject.find(params[:geo_project_id])
        unless @project.status == "active"
          Rails.logger.info "[ACCESS] DENY reason=project_not_published project_id=#{@project.id} status=#{@project.status}"
          render json: { message: "Proyecto no publicado" }, status: :forbidden
        end
      end

      def set_point
        @point = @project.geo_points.find_by(id: params[:id], active: true)
        unless @point
          Rails.logger.info "[ACCESS] DENY reason=point_not_found point_id=#{params[:id]} project_id=#{@project.id}"
          render json: { message: "Punto no encontrado" }, status: :not_found
        end
      end

      def render_deny(message)
        Rails.logger.info "[ACCESS] ── RESPONSE deny message=#{message.inspect}"
        render json: { success: false, message: }, status: :unprocessable_entity
      end

      # ── Haversine ──────────────────────────────────────────────────────────────

      def haversine(lat1, lng1, lat2, lng2)
        r    = 6_371_000.0
        phi1 = lat1 * Math::PI / 180
        phi2 = lat2 * Math::PI / 180
        dphi = (lat2 - lat1) * Math::PI / 180
        dlam = (lng2 - lng1) * Math::PI / 180
        a    = Math.sin(dphi / 2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlam / 2)**2
        2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
      end

      # ── Schedule ───────────────────────────────────────────────────────────────

      def schedule_ok?
        av = @point.availability || {}
        return true unless av["schedule_enabled"]

        week_days = %w[Dom Lun Mar Mié Jue Vie Sáb]
        today     = week_days[Time.current.wday]
        days      = av["schedule_days"] || []

        return false if days.any? && !days.include?(today)

        st = av["schedule_start_time"]
        et = av["schedule_end_time"]
        if st && et
          cur = Time.current.strftime("%H:%M")
          return false if cur < st || cur > et
        end

        true
      end

      # ── Quota ──────────────────────────────────────────────────────────────────

      def quota_active?
        av = @point.availability || {}
        av["quota_enabled"] && av["quota_limit"].present?
      end

      # Atomically decrements quota_used. Returns an error message string on
      # failure (exhausted), or nil on success.
      def try_decrement_quota
        error = nil
        GeoPoint.transaction do
          @point.lock!
          @point.reload
          av    = @point.availability || {}
          limit = av["quota_limit"].to_i
          used  = av["quota_used"].to_i
          if used >= limit
            error = "No quedan cupos disponibles"
            raise ActiveRecord::Rollback
          end
          av["quota_used"] = used + 1
          @point.update_column(:availability, av)
        end
        error
      end
    end
  end
end
