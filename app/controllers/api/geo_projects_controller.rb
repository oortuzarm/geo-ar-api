module Api
  class GeoProjectsController < ApplicationController
    before_action :set_project, only: %i[show update destroy sync]

    # GET /api/geo_projects
    def index
      projects = GeoProject.all.order(updated_at: :desc)
      render json: projects.map(&:as_api_json)
    end

    # GET /api/geo_projects/:id
    def show
      render json: @project.as_api_json
    end

    # POST /api/geo_projects
    def create
      project = GeoProject.create!(project_params)
      render json: project.as_api_json, status: :created
    end

    # PUT /api/geo_projects/:id
    def update
      @project.update!(project_params)
      render json: @project.as_api_json
    end

    # DELETE /api/geo_projects/:id
    def destroy
      @project.destroy!
      head :no_content
    end

    # PATCH /api/geo_projects/:id/sync
    # Saves the project and all its points in a single transaction.
    # Payload: { title, subtitle, ..., geoPoints: [ { id?, name, latitude, ... } ] }
    def sync
      sp = sync_params
      incoming_points = sp[:geo_points] || []
      incoming_ids    = incoming_points.filter_map { |p| p[:id].presence }

      ActiveRecord::Base.transaction do
        @project.update!(sp.except(:geo_points))

        # Remove points that are no longer in the payload
        @project.geo_points.where.not(id: incoming_ids).destroy_all

        incoming_points.each do |pt|
          attrs = pt.except(:id).to_h
          if pt[:id].present?
            point = @project.geo_points.find_by(id: pt[:id])
            point&.update!(attrs)
          else
            @project.geo_points.create!(attrs)
          end
        end
      end

      @project.reload
      render json: @project.as_api_json_with_points
    end

    private

    def set_project
      @project = GeoProject.find(params[:id])
    end

    def project_params
      params.permit(:title, :subtitle, :description, :cover_image, :how_to_get, :status)
    end

    def sync_params
      params.permit(
        :title, :subtitle, :description, :cover_image, :how_to_get,
        geo_points: [
          :id, :name, :lookiar_url, :latitude, :longitude,
          :activation_radius, :image, :description, :instructions,
          :active, :order, :button_text,
          availability: [
            :schedule_enabled, :quota_enabled, :quota_limit, :quota_used,
            :schedule_start_time, :schedule_end_time,
            schedule_days: [],
          ],
        ],
      )
    end
  end
end
