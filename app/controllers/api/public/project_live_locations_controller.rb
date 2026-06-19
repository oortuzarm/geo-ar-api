module Api
  module Public
    class ProjectLiveLocationsController < ApplicationController
      # POST /api/public/geo_projects/:id/live_location
      # Public — no authentication required.
      # Body: { session_id, lat, lng, accuracy? }
      # Returns: { insideAreas: bool }
      #
      # Upserts a ProjectLiveVisit (one row per session per project) and records
      # at most one AnalyticsEvent with event_type "project_location" per session
      # per day — enough for historical people metrics without excessive volume.

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
          render json: { error: "session_id inválido." }, status: :unprocessable_entity
          return
        end

        project = GeoProject.find_by(id: params[:id], status: "active")
        unless project
          render json: { error: "Proyecto no encontrado." }, status: :not_found
          return
        end

        lat      = params[:lat].to_f
        lng      = params[:lng].to_f
        accuracy = params[:accuracy]&.to_f

        active_points = project.geo_points.where(active: true).to_a
        inside_areas  = active_points.any? { |pt| GeoEngine.inside_boundary?(pt, lat, lng) }

        upsert_live_visit(project, session_id, lat, lng, accuracy)
        record_daily_event(project, session_id, lat, lng, was_inside: inside_areas)

        render json: { insideAreas: inside_areas }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # One row per (project, session) — always reflects the latest known position.
      def upsert_live_visit(project, session_id, lat, lng, accuracy)
        visit = ProjectLiveVisit.find_or_initialize_by(
          geo_project_id: project.id,
          session_id:     session_id
        )
        visit.assign_attributes(
          lat:          lat,
          lng:          lng,
          accuracy:     accuracy,
          last_seen_at: Time.current
        )
        visit.save!
      end

      # One AnalyticsEvent per (session, project, calendar day).
      # Coordinates track the last known position of the day.
      # had_inside_position / had_outside_position are ratchet flags that accumulate
      # whether this session has ever been inside or outside any active GeoPoint
      # boundary. The OR in the ON CONFLICT SET clause ensures a flag that is already
      # true can never be overwritten with false. Classification at query time uses
      # these flags directly — no GeoEngine call is needed at read time.
      def record_daily_event(project, session_id, lat, lng, was_inside:)
        AnalyticsEvent.upsert_all(
          [{
            geo_project_id:       project.id,
            session_id:           session_id,
            event_type:           "project_location",
            event_date:           Date.current,
            latitude:             lat,
            longitude:            lng,
            source:               "public",
            had_inside_position:  was_inside,
            had_outside_position: !was_inside
          }],
          unique_by: :idx_analytics_events_project_location_uniqueness,
          on_duplicate: Arel.sql(<<~SQL.chomp)
            latitude             = EXCLUDED.latitude,
            longitude            = EXCLUDED.longitude,
            had_inside_position  = analytics_events.had_inside_position  OR EXCLUDED.had_inside_position,
            had_outside_position = analytics_events.had_outside_position OR EXCLUDED.had_outside_position,
            updated_at           = EXCLUDED.updated_at
          SQL
        )
      end

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
