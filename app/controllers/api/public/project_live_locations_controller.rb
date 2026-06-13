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

        upsert_live_visit(project, session_id, lat, lng, accuracy)
        record_daily_event(project, session_id, lat, lng)

        active_points = project.geo_points.where(active: true).to_a
        inside_areas  = active_points.any? { |pt| GeoEngine.inside_boundary?(pt, lat, lng) }

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
      # Coordinates are updated on every ping so the stored position always
      # reflects the last known location of the session during that day.
      # Classification (inside / outside) happens at query time via GeoEngine.inside_boundary?.
      def record_daily_event(project, session_id, lat, lng)
        event = AnalyticsEvent.find_or_initialize_by(
          geo_project_id: project.id,
          session_id:     session_id,
          event_type:     "project_location",
          event_date:     Date.current
        )
        event.latitude = lat
        event.longitude = lng
        event.source ||= "public"
        event.save!
      rescue ActiveRecord::RecordNotUnique
        # Race condition on insert: a concurrent request created the row first.
        # Retry so the update path runs against the now-existing record.
        retry
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
