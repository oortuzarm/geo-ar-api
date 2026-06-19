module Api
  module V1
    class ProjectsController < BaseController
      before_action -> { require_scope!("projects:read") }

      def index
        projects = organization_projects
          .includes(:geo_points)
          .order(created_at: :desc)

        render_ok(
          Api::V1::ProjectBlueprint.render_as_hash(projects),
          meta: { count: projects.size }
        )
      end

      def show
        project = find_organization_project(params[:id])
        render_ok(Api::V1::ProjectBlueprint.render_as_hash(project))
      end

      private

      def find_organization_project(id)
        project = organization_projects.find(id)
        project.geo_points.load
        project
      end
    end
  end
end
