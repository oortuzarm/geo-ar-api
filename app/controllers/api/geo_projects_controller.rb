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
      started_at = Time.current
      sp  = sync_params
      pts = (sp[:geo_points] || []).map(&:to_h)

      Rails.logger.info "[SYNC] START project=#{@project.id} points=#{pts.size}"

      now = Time.current

      ActiveRecord::Base.transaction do
        # 1. Update project fields — 1 query
        project_attrs = sp.except(:geo_points).to_h
        @project.update!(project_attrs) if project_attrs.any?

        # 2. Delete removed points in batch — 1 query, no callbacks
        incoming_ids = pts.filter_map { |p| p["id"].presence }
        @project.geo_points.where.not(id: incoming_ids).delete_all

        # 3. Upsert all incoming points — 1 query (new + existing)
        unless pts.empty?
          records = pts.map do |pt|
            {
              "id"                => pt["id"].presence || SecureRandom.uuid,
              "geo_project_id"    => @project.id,
              "name"              => pt["name"],
              "lookiar_url"       => pt["lookiar_url"],
              "latitude"          => pt["latitude"],
              "longitude"         => pt["longitude"],
              "activation_radius" => pt["activation_radius"],
              "image"             => pt["image"],
              "description"       => pt["description"],
              "instructions"      => pt["instructions"],
              "button_text"       => pt["button_text"],
              "active"            => pt.fetch("active", true),
              "order"             => pt.fetch("order", 0),
              "availability"      => pt.fetch("availability", {}),
              "created_at"        => now,
              "updated_at"        => now,
            }
          end

          GeoPoint.upsert_all(
            records,
            unique_by: :id,
            update_only: %w[
              name lookiar_url latitude longitude activation_radius
              image description instructions button_text active order
              availability updated_at
            ],
          )
        end
      end

      elapsed = ((Time.current - started_at) * 1000).round
      Rails.logger.info "[SYNC] END #{elapsed}ms"

      render json: { success: true, project_id: @project.id }
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
