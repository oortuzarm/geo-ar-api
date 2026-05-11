module Api
  module Admin
    class ProjectsController < BaseController
      # GET /api/admin/projects
      # Returns all projects with owner email and point count.
      # Single query via LEFT JOINs; groups by PK so PG derives other columns.
      def index
        projects = GeoProject
          .left_joins(:user, :geo_points)
          .select(
            "geo_projects.id",
            "geo_projects.title",
            "geo_projects.status",
            "geo_projects.user_id",
            "geo_projects.created_at",
            "geo_projects.updated_at",
            "users.email AS user_email",
            "COUNT(geo_points.id) AS points_count"
          )
          .group("geo_projects.id", "users.email")
          .order("geo_projects.updated_at DESC")

        render json: projects.map { |p|
          {
            id:          p.id,
            title:       p.title,
            status:      p.status,
            userId:      p.user_id,
            userEmail:   p.user_email,
            pointsCount: p.points_count.to_i,
            isOrphan:    p.user_id.nil?,
            createdAt:   p.created_at.iso8601(3),
            updatedAt:   p.updated_at.iso8601(3)
          }
        }
      end
    end
  end
end
