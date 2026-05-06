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
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      payload_kb = (request.content_length.to_f / 1024).round(1)
      Rails.logger.info "[SAVE_PERF] ── START project=#{@project.id} payload_size=#{payload_kb}KB"

      sp  = sync_params
      pts = (sp[:geo_points] || []).map(&:to_h)

      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "[SAVE_PERF] parse_ms=#{ms(t0, t1)} points_count=#{pts.size}"

      cover_kb  = sp[:cover_image].to_s.bytesize / 1024.0
      img_sizes = pts.map { |p| p["image"].to_s.bytesize }
      pts_with_images = img_sizes.count(&:positive?)
      total_img_kb = img_sizes.sum / 1024.0
      Rails.logger.info "[SAVE_PERF] cover_image_kb=#{cover_kb.round(1)} pts_with_images=#{pts_with_images}/#{pts.size} total_point_images_kb=#{total_img_kb.round(1)}"

      now = Time.current
      t2  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      ActiveRecord::Base.transaction do
        # 1. Update project fields — 1 query
        project_attrs = sp.except(:geo_points).to_h
        @project.update!(project_attrs) if project_attrs.any?
        t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Rails.logger.info "[SAVE_PERF] project_update_ms=#{ms(t2, t3)}"

        # 2. Delete removed points in batch — 1 query, no callbacks
        incoming_ids = pts.filter_map { |p| p["id"].presence }
        @project.geo_points.where.not(id: incoming_ids).delete_all
        t4 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Rails.logger.info "[SAVE_PERF] delete_ms=#{ms(t3, t4)}"

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

        t5 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Rails.logger.info "[SAVE_PERF] upsert_ms=#{ms(t4, t5)}"
      end

      t6 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "[SAVE_PERF] transaction_ms=#{ms(t2, t6)}"

      t7 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rails.logger.info "[SAVE_PERF] total_ms=#{ms(t0, t7)}"

      render json: { success: true, project_id: @project.id, points_count: pts.size }
    end

    private

    def ms(t_start, t_end)
      ((t_end - t_start) * 1000).round
    end

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
