module Api
  class GeoProjectsController < ApplicationController
    before_action :set_project, only: %i[show update destroy]

    # GET /api/geo-projects
    def index
      projects = GeoProject.all.order(updated_at: :desc)
      render json: projects.map(&:as_api_json)
    end

    # GET /api/geo-projects/:id
    def show
      render json: @project.as_api_json
    end

    # POST /api/geo-projects
    def create
      project = GeoProject.create!(project_params)
      render json: project.as_api_json, status: :created
    end

    # PUT /api/geo-projects/:id
    def update
      @project.update!(project_params)
      render json: @project.as_api_json
    end

    # DELETE /api/geo-projects/:id
    def destroy
      @project.destroy!
      head :no_content
    end

    private

    def set_project
      @project = GeoProject.find(params[:id])
    end

    def project_params
      params.permit(:title, :subtitle, :description, :cover_image, :how_to_get, :status)
    end
  end
end
