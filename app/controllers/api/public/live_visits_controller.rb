module Api
  module Public
    class LiveVisitsController < ApplicationController
      # POST /api/public/geo_points/:id/live_visit
      # Public — no authentication required.
      # Body: { sessionId, lat, lng, accuracy? }
      # Returns: { insideRadius, distanceMeters, radiusMeters }

      # crypto.randomUUID() in the browser always produces UUID v4.
      SESSION_ID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.freeze
      SESSION_ID_MIN   = 8
      SESSION_ID_MAX   = 128
      private_constant :SESSION_ID_REGEX, :SESSION_ID_MIN, :SESSION_ID_MAX

      def create
        unless valid_coordinates?
          render json: { error: "lat y lng son obligatorios y deben ser numéricos." },
                 status: :unprocessable_entity
          return
        end

        session_id = params[:session_id].to_s
        unless valid_session_id?(session_id)
          Rails.logger.warn "[LIVE_VISIT] Rejected — invalid session_id point_id=#{params[:id]} len=#{session_id.length}"
          render json: { error: "session_id inválido." }, status: :unprocessable_entity
          return
        end

        point = GeoPoint.joins(:geo_project)
                        .where(geo_projects: { status: "active" })
                        .find_by(id: params[:id])

        unless point
          exists = GeoPoint.exists?(id: params[:id])
          Rails.logger.warn "[LIVE_VISIT] Rejected — #{exists ? "project not active" : "point not found"} " \
                            "point_id=#{params[:id]} session_id=#{session_id[0, 8]}…"
          render json: { error: "Punto no encontrado." }, status: :not_found
          return
        end

        lat      = params[:lat].to_f
        lng      = params[:lng].to_f
        accuracy = params[:accuracy]&.to_f
        dist     = GeoEngine.distance_to(point, lat, lng)
        inside   = GeoEngine.inside_boundary?(point, lat, lng)

        visit = GeoPointLiveVisit.find_or_initialize_by(
          geo_point_id: point.id,
          session_id:   session_id
        )
        visit.assign_attributes(
          geo_project_id: point.geo_project_id,
          lat:            lat,
          lng:            lng,
          accuracy:       accuracy,
          inside_radius:  inside,
          last_seen_at:   Time.current
        )
        visit.save!

        render json: {
          insideRadius:   inside,
          distanceMeters: dist.round(1),
          radiusMeters:   point.activation_radius,
          active_now:     GeoEngine.live_visits_count(point)
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def valid_coordinates?
        numeric?(params[:lat]) && numeric?(params[:lng])
      end

      def valid_session_id?(sid)
        return false if sid.length < SESSION_ID_MIN || sid.length > SESSION_ID_MAX
        SESSION_ID_REGEX.match?(sid)
      end

      def numeric?(value)
        return false if value.nil?
        Float(value)
        true
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
