module Api
  module V1
    class LocationsController < BaseController
      before_action :set_project, only: %i[index]

      def index
        locations = @project.geo_points.order(:order)
        render_ok(
          Api::V1::LocationBlueprint.render_as_hash(locations),
          meta: { count: locations.size }
        )
      end

      def show
        location = find_organization_location(params[:id])
        render_ok(Api::V1::LocationBlueprint.render_as_hash(location))
      end

      private

      def set_project
        @project = organization_projects.find(params[:project_id])
      end

      def find_organization_location(id)
        GeoPoint.joins(:geo_project)
          .where(geo_projects: { user_id: current_organization.memberships.select(:user_id) })
          .find(id)
      end
    end
  end
end
