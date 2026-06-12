module Api
  class GeoPointsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project,               only: %i[index create]
    before_action :authorize_project_access!, only: %i[index create]
    before_action :enforce_location_limit!,   only: %i[create]
    before_action :set_point,                 only: %i[update destroy]
    before_action :authorize_point_access!,   only: %i[update destroy]
    before_action :check_dwell_time_feature!, only: %i[create update]

    # GET /api/geo-projects/:geo_project_id/geo-points
    def index
      render json: @project.geo_points.map(&:as_api_json)
    end

    # POST /api/geo-projects/:geo_project_id/geo-points
    def create
      point = @project.geo_points.create!(point_params)
      render json: point.as_api_json, status: :created
    end

    # PUT /api/geo-points/:id
    def update
      @point.update!(point_params)
      render json: @point.as_api_json
    end

    # DELETE /api/geo-points/:id
    def destroy
      @point.destroy!
      head :no_content
    end

    private

    def set_project
      @project = if current_user.role == "admin"
                   GeoProject.find(params[:geo_project_id])
                 elsif current_organization
                   current_organization.geo_projects.find(params[:geo_project_id])
                 else
                   raise ActiveRecord::RecordNotFound
                 end
    end

    def set_point
      @point = if current_user.role == "admin"
                 GeoPoint.find(params[:id])
               elsif current_organization
                 GeoPoint.joins(:geo_project)
                         .where(geo_projects: { organization_id: current_organization.id })
                         .find(params[:id])
               else
                 raise ActiveRecord::RecordNotFound
               end
    end

    def authorize_project_access!
      authorize_project!(@project)
    end

    def authorize_point_access!
      authorize_project!(@point.geo_project)
    end

    def point_params
      params.permit(
        :name, :lookiar_url, :content_type, :destination_category, :point_mode,
        :latitude, :longitude, :activation_radius, :activation_mode,
        :image, :description, :instructions, :active, :order, :button_text,
        :requires_dwell_time, :dwell_time_seconds,
        :point_logo_url, :point_logo_zoom, :point_logo_position_x, :point_logo_position_y,
        :point_video_url, :point_video_type,
        content_data:        {},
        activation_polygon:  {},
        images: %i[id url is_cover is_Cover isCover position],
        availability: [
          :schedule_enabled, :quota_enabled, :quota_limit, :quota_used,
          :schedule_start_time, :schedule_end_time,
          :live_visits_enabled, :live_visits_minimum,
          schedule_days: []
        ],
      )
    end

    def check_dwell_time_feature!
      return if current_user.role == "admin"
      return unless [ true, "true", "1" ].include?(params[:requires_dwell_time])

      config = current_user.plan&.effective_features_config || Plan::FULL_FEATURES_CONFIG
      return if config["dwell_time"]

      render json: { error: "Tu plan no incluye la función de Permanencia." }, status: :forbidden
      throw :abort
    end
  end
end
