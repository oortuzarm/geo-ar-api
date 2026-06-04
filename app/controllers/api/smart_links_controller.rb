module Api
  # Studio CRUD for Smart Links — session-authenticated.
  # Scoped to current_user (admins can access any link).
  class SmartLinksController < ApplicationController
    before_action :authenticate_user!
    before_action :set_smart_link, only: %i[show update destroy]

    # GET /api/smart_links
    def index
      links = smart_links_scope
                .where.not(status: "archived")
                .includes(:smart_link_geo_points)
                .order(created_at: :desc)
      render json: links.map(&:as_api_json)
    end

    # GET /api/smart_links/:id
    def show
      render json: @smart_link.as_api_json
    end

    # POST /api/smart_links
    def create
      @smart_link = SmartLink.new(smart_link_params.merge(user_id: current_user.id))

      unless project_owned_by_user?(@smart_link.project_id)
        return render json: { error: "Proyecto no encontrado." }, status: :not_found
      end

      resolved_ids = nil
      if @smart_link.scope_type == "geo_points"
        resolved_ids = valid_geo_point_ids(@smart_link.project_id)
        if resolved_ids.empty?
          return render json: { error: "Se requiere al menos un punto válido para scope_type geo_points." },
                        status: :unprocessable_entity
        end
      end

      SmartLink.transaction do
        resolved_ids&.each { |id| @smart_link.smart_link_geo_points.build(geo_point_id: id) }
        @smart_link.save!
      end

      render json: @smart_link.reload.as_api_json, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first }, status: :unprocessable_entity
    end

    # PATCH /api/smart_links/:id
    def update
      @smart_link.assign_attributes(smart_link_params)

      resolved_ids = nil
      if @smart_link.scope_type == "geo_points" && params.key?(:geo_point_ids)
        resolved_ids = valid_geo_point_ids(@smart_link.project_id)
        if resolved_ids.empty?
          return render json: { error: "Se requiere al menos un punto válido para scope_type geo_points." },
                        status: :unprocessable_entity
        end
      end

      SmartLink.transaction do
        if resolved_ids
          @smart_link.smart_link_geo_points.destroy_all
          resolved_ids.each { |id| @smart_link.smart_link_geo_points.build(geo_point_id: id) }
        end
        @smart_link.save!
      end

      render json: @smart_link.reload.as_api_json
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first }, status: :unprocessable_entity
    end

    # DELETE /api/smart_links/:id  — soft delete
    def destroy
      @smart_link.update!(status: "archived")
      head :no_content
    end

    private

    def set_smart_link
      @smart_link = smart_links_scope.includes(:smart_link_geo_points).find(params[:id])
    end

    def smart_links_scope
      current_user.role == "admin" ? SmartLink : current_user.smart_links
    end

    def smart_link_params
      params.permit(:name, :slug, :project_id, :scope_type, :destination_type,
                    :destination_url, :status, ui_config: {})
    end

    def project_owned_by_user?(project_id)
      return true if current_user.role == "admin"
      current_user.geo_projects.exists?(id: project_id)
    end

    def valid_geo_point_ids(project_id)
      return [] if params[:geo_point_ids].blank?
      GeoPoint.joins(:geo_project)
              .where(geo_projects: { user_id: current_user.id })
              .where(geo_project_id: project_id)
              .where(id: Array(params[:geo_point_ids]))
              .pluck(:id)
    end
  end
end
