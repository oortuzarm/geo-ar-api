module Api
  class AnalyticsEventsController < ApplicationController
    # POST /api/analytics_events
    # Body (camelCase — normalize_params converts to snake_case):
    #   { projectId, pointId, eventType, sessionId }
    # Idempotent: duplicate events (same point+type+session+day) return success
    # without creating a new record.
    def create
      attrs = {
        geo_project_id: params[:project_id],
        geo_point_id:   params[:point_id],
        event_type:     params[:event_type],
        session_id:     params[:session_id],
        event_date:     Date.current,
      }

      event = AnalyticsEvent.find_or_initialize_by(attrs)

      if event.persisted?
        render json: { success: true, created: false }
      else
        event.save!
        render json: { success: true, created: true }, status: :created
      end
    end

    # GET /api/geo_projects/:id/analytics
    def stats
      project        = GeoProject.find(params[:id])
      radius_entries = project.analytics_events.where(event_type: "radius_enter").count
      clicks         = project.analytics_events.where(event_type: "point_click").count
      conversion     = radius_entries > 0 ? (clicks.to_f / radius_entries * 100).round : 0

      render json: {
        radiusEntries: radius_entries,
        clicks:        clicks,
        conversion:    conversion,
      }
    end
  end
end
