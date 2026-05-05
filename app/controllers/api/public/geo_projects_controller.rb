module Api
  module Public
    class GeoProjectsController < ApplicationController
      # GET /api/public/geo_projects/:id
      # No authentication required.
      # Returns 404 if the project doesn't exist.
      # Returns 403 if the project exists but is not active (not published).
      def show
        project = GeoProject.find(params[:id])

        unless project.status == "active"
          render json: { error: "Este proyecto no está publicado." }, status: :forbidden
          return
        end

        render json: project.as_api_json
      end

      # POST /api/public/geo_projects
      # Temporal: crea un proyecto demo con datos hardcodeados para testing.
      def create
        project = GeoProject.create!(
          title: "Proyecto Demo",
          status: "active"
        )

        render json: project.as_api_json, status: :created
      end
    end
  end
end
