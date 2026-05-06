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

        dist = haversine(lat, lng, @point.latitude, @point.longitude)
        return render_deny("Debes estar dentro del área para acceder") if dist > @point.activation_radius

        return render_deny("Esta experiencia está fuera del horario disponible") unless schedule_ok?

        if quota_active?
          msg = try_decrement_quota
          return render_deny(msg) if msg
        end

        render json: { url: @point.lookiar_url }
      end

      private

      def set_project
        @project = GeoProject.find(params[:geo_project_id])
        render json: { message: "Proyecto no publicado" }, status: :forbidden unless @project.status == "active"
      end

      def set_point
        @point = @project.geo_points.find_by(id: params[:id], active: true)
        render json: { message: "Punto no encontrado" }, status: :not_found unless @point
      end

      def render_deny(message)
        render json: { message: }, status: :unprocessable_entity
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
