module Api
  class GeoPointsController < ApplicationController
    before_action :set_project,   only: %i[index create]
    before_action :set_point,     only: %i[update destroy]

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
      @project = GeoProject.find(params[:geo_project_id])
    end

    def set_point
      @point = GeoPoint.find(params[:id])
    end

    def point_params
      params.permit(
        :name, :lookiar_url, :latitude, :longitude,
        :activation_radius, :image, :description,
        :instructions, :active, :order
      )
    end
  end
end
