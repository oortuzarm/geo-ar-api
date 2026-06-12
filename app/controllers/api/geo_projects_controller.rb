module Api
  class GeoProjectsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project,               only: %i[show update destroy sync]
    before_action :authorize_project_access!, only: %i[show update destroy sync]

    # GET /api/geo_projects
    # Scoped to current organization. All members of the org see all org projects.
    # Admin global access lives exclusively in /api/admin.
    def index
      org      = current_organization
      projects = org ? org.geo_projects.order(updated_at: :desc).to_a : []
      Rails.logger.info "[GEO_PROJECTS_INDEX_SCOPE] user_id=#{current_user.id} " \
                        "email=#{current_user.email} role=#{current_user.role} " \
                        "org_id=#{org&.id} count=#{projects.size}"
      render json: projects.map(&:as_api_json)
    end

    # GET /api/geo_projects/:id
    def show
      json = @project.as_api_json
      Rails.logger.info "[GeoProject#show] id=#{@project.id} publicInitialViewMode=#{json[:publicInitialViewMode].inspect} publicInitialZoom=#{json[:publicInitialZoom].inspect}"
      render json: json
    end

    # POST /api/geo_projects
    def create
      org = current_organization
      return render json: { error: "No perteneces a ninguna organización." }, status: :forbidden unless org
      project = org.geo_projects.create!(project_params.merge(user_id: current_user.id))
      render json: project.as_api_json, status: :created
    end

    # PUT /api/geo_projects/:id
    def update
      Rails.logger.info "[GEO_PROJECT_UPDATE_REQUEST] user_id=#{current_user.id} " \
                        "email=#{current_user.email} role=#{current_user.role} " \
                        "param_id=#{params[:id]} loaded_project_id=#{@project.id} " \
                        "loaded_project_owner_id=#{@project.user_id} status_param=#{params[:status].inspect}"
      @project.update!(project_params)
      render json: @project.as_api_json
    end

    # DELETE /api/geo_projects/:id
    def destroy
      Rails.logger.info "[GEO_PROJECT_DESTROY_REQUEST] user_id=#{current_user.id} " \
                        "email=#{current_user.email} role=#{current_user.role} " \
                        "param_id=#{params[:id]} loaded_project_id=#{@project.id} " \
                        "loaded_project_owner_id=#{@project.user_id}"
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

      # Temporary: log content fields to verify payload shape
      pts.each do |pt|
        Rails.logger.info "[SYNC_DEBUG] point id=#{pt['id'].inspect} content_type=#{pt['content_type'].inspect} content_data_keys=#{pt.fetch('content_data', {}).keys.inspect} lookiar_url=#{pt['lookiar_url'].inspect}"
      end

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

        # 3. Upsert all incoming points.
        #
        # The frontend skips re-sending unchanged base64 images to keep payloads small.
        # When the `image` key is absent from a point's payload we must NOT overwrite the
        # stored value with NULL.  We detect this by checking pt.key?("image"):
        #   - key present (value is a string or nil) → image changed; include in UPDATE
        #   - key absent                              → image unchanged; exclude from UPDATE
        #
        # This requires two separate upsert_all calls with different update_only columns.
        unless pts.empty?
          build_record = lambda do |pt|
            {
              "id"                   => pt["id"].presence || SecureRandom.uuid,
              "geo_project_id"       => @project.id,
              "name"                 => pt["name"],
              "lookiar_url"          => pt["lookiar_url"].to_s,
              "content_type"         => pt.fetch("content_type", "url").presence || "url",
              "content_data"         => pt.fetch("content_data", {}) || {},
              "destination_category" => pt["destination_category"].presence,
              "latitude"          => pt["latitude"],
              "longitude"         => pt["longitude"],
              "activation_radius" => pt["activation_radius"],
              "image"             => pt["image"],
              "images"            => GeoPoint.normalize_images(pt.fetch("images", [])),
              "description"       => pt["description"],
              "instructions"      => pt["instructions"],
              "button_text"       => pt["button_text"],
              "active"               => pt.fetch("active", true),
              "order"                => pt.fetch("order", 0),
              "availability"         => pt.fetch("availability", {}),
              "activation_mode"      => pt.fetch("activation_mode", "radius").presence || "radius",
              "activation_polygon"   => pt.fetch("activation_polygon", nil),
              "point_logo_url"        => pt["point_logo_url"],
              "point_logo_zoom"       => pt["point_logo_zoom"],
              "point_logo_position_x" => pt["point_logo_position_x"],
              "point_logo_position_y" => pt["point_logo_position_y"],
              "point_video_url"       => pt["point_video_url"],
              "point_video_type"      => pt["point_video_type"],
              "point_mode"           => pt.fetch("point_mode", "unlock").presence || "unlock",
              "created_at"           => now,
              "updated_at"           => now
            }
          end

          base_columns = %w[
            name lookiar_url content_type content_data destination_category
            latitude longitude activation_radius activation_mode activation_polygon
            description instructions button_text active order
            availability images updated_at
            point_logo_url point_logo_zoom point_logo_position_x point_logo_position_y
            point_video_url point_video_type point_mode
          ]

          pts_with_image    = pts.select { |p| p.key?("image") }
          pts_without_image = pts.reject { |p| p.key?("image") }

          if pts_with_image.any?
            GeoPoint.upsert_all(
              pts_with_image.map(&build_record),
              unique_by: :id,
              update_only: base_columns + %w[image],
            )
          end

          if pts_without_image.any?
            GeoPoint.upsert_all(
              pts_without_image.map(&build_record),
              unique_by: :id,
              update_only: base_columns,
            )
          end
        end

        t5 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Rails.logger.info "[SAVE_PERF] upsert_ms=#{ms(t4, t5)}"

        # 4. Sync collection requirements per point.
        # Only processes points that explicitly send required_point_ids (key present),
        # so old clients that omit the key never accidentally clear existing data.
        pts.each do |pt|
          point_id = pt["id"].presence
          next unless point_id
          next unless pt.key?("required_point_ids")

          raw_required = Array(pt["required_point_ids"])
                           .filter_map { |r| r.to_s.presence }
                           .uniq
          GeoPointCollection.where(geo_point_id: point_id).delete_all
          valid = raw_required.reject { |rid| rid == point_id }
          if valid.any?
            GeoPointCollection.insert_all(
              valid.map { |rid|
                { geo_point_id: point_id, required_geo_point_id: rid,
                  created_at: now, updated_at: now }
              }
            )
          end
        end
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
      @project = if current_user.role == "admin"
                   GeoProject.find(params[:id])
                 elsif current_organization
                   current_organization.geo_projects.find(params[:id])
                 else
                   raise ActiveRecord::RecordNotFound
                 end
    end

    def authorize_project_access!
      authorize_project!(@project)
    end

    def project_params
      params.permit(
        :title, :subtitle, :description, :cover_image, :how_to_get, :share_text, :status,
        :public_initial_view_mode, :public_initial_center_lat, :public_initial_center_lng, :public_initial_zoom,
        :community_enabled, :project_logo_url, :project_logo_zoom,
        :project_logo_position_x, :project_logo_position_y,
      )
    end

    def sync_params
      params.permit(
        :title, :subtitle, :description, :cover_image, :how_to_get, :share_text,
        :public_initial_view_mode, :public_initial_center_lat, :public_initial_center_lng, :public_initial_zoom,
        :project_logo_url, :project_logo_zoom, :project_logo_position_x, :project_logo_position_y,
        geo_points: [
          :id, :name, :lookiar_url, :content_type, :destination_category,
          :latitude, :longitude, :activation_radius, :activation_mode,
          :image, :description, :instructions, :active, :order, :button_text,
          :point_logo_url, :point_logo_zoom, :point_logo_position_x, :point_logo_position_y,
          :point_video_url, :point_video_type, :point_mode,
          required_point_ids: [],
          content_data:       {},
          activation_polygon: {},
          images: [ :id, :url, :is_cover, :isCover, :position ],
          availability: [
            :schedule_enabled, :quota_enabled, :quota_limit, :quota_used,
            :schedule_start_time, :schedule_end_time,
            :live_visits_enabled, :live_visits_minimum,
            schedule_days: []
          ]
        ],
      )
    end
  end
end
