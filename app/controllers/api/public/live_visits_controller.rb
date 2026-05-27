module Api
  module Public
    class LiveVisitsController < ApplicationController
      # POST /api/public/geo_points/:id/live_visit
      # Public — no authentication required.
      # Body: { sessionId, lat, lng, accuracy? }
      # Returns: { insideRadius, distanceMeters, radiusMeters }
      def create
        point = GeoPoint.find(params[:id])

        unless valid_params?
          render json: { error: "session_id, lat y lng son obligatorios y deben ser numéricos." },
                 status: :unprocessable_entity
          return
        end

        lat        = params[:lat].to_f
        lng        = params[:lng].to_f
        accuracy   = params[:accuracy]&.to_f
        session_id = params[:session_id].to_s
        dist       = haversine(lat, lng, point.latitude, point.longitude)
        inside     = dist <= point.activation_radius

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
          radiusMeters:   point.activation_radius
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Punto no encontrado." }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def valid_params?
        params[:session_id].present? &&
          numeric?(params[:lat]) &&
          numeric?(params[:lng])
      end

      def numeric?(value)
        return false if value.nil?
        Float(value)
        true
      rescue ArgumentError, TypeError
        false
      end

      def haversine(lat1, lng1, lat2, lng2)
        r    = 6_371_000.0
        phi1 = lat1 * Math::PI / 180
        phi2 = lat2 * Math::PI / 180
        dphi = (lat2 - lat1) * Math::PI / 180
        dlam = (lng2 - lng1) * Math::PI / 180
        a    = Math.sin(dphi / 2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlam / 2)**2
        2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
      end
    end
  end
end
