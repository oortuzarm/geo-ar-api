module Api
  module Admin
    class UsersController < BaseController
      # GET /api/admin/users
      # Returns all users with their project and point counts.
      # Single query via LEFT JOINs to avoid N+1.
      def index
        users = User
          .left_joins(geo_projects: :geo_points)
          .select(
            "users.id",
            "users.email",
            "users.role",
            "users.status",
            "users.created_at",
            "users.updated_at",
            "COUNT(DISTINCT geo_projects.id) AS projects_count",
            "COUNT(geo_points.id) AS points_count"
          )
          .group("users.id")
          .order("users.created_at DESC")

        render json: users.map { |u|
          {
            id:            u.id,
            email:         u.email,
            role:          u.role,
            status:        u.status,
            projectsCount: u.projects_count.to_i,
            pointsCount:   u.points_count.to_i,
            createdAt:     u.created_at.iso8601(3),
            updatedAt:     u.updated_at.iso8601(3)
          }
        }
      end
    end
  end
end
