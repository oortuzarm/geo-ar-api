module Api
  module Community
    class ProjectsController < ApplicationController
      # GET /api/community/projects
      # Public — no auth required.
      # Returns only projects that are: published, community-enabled, admin-approved,
      # owned by an existing user with active subscription or active trial.
      def index
        projects = GeoProject
          .where(status: "active", community_enabled: true, community_status: "approved")
          .where.not(user_id: nil)
          .includes(:user, :geo_points)
          .order(updated_at: :desc)
          .select { |p| p.user&.subscription_active? }

        render json: projects.map { |p| project_json(p) }
      end

      private

      def project_json(project)
        active_points = project.geo_points.select(&:active)
        {
          id:          project.id,
          title:       project.title,
          description: project.description,
          coverImage:  project.cover_image,
          publicUrl:   "/public/#{project.id}",
          pointsCount: project.geo_points.size,
          points: active_points.map { |pt|
            { id: pt.id, name: pt.name, latitude: pt.latitude, longitude: pt.longitude }
          },
        }
      end
    end
  end
end
