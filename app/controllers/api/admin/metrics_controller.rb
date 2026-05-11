module Api
  module Admin
    class MetricsController < BaseController
      # GET /api/admin/metrics
      # Aggregate platform-wide counters. Each count is a separate fast index scan.
      def index
        render json: {
          totalUsers:             User.count,
          totalAdmins:            User.where(role: "admin").count,
          totalActiveUsers:       User.where(status: "active").count,
          totalSuspendedUsers:    User.where(status: "suspended").count,
          totalProjects:          GeoProject.count,
          totalPublishedProjects: GeoProject.where(status: "active").count,
          totalDraftProjects:     GeoProject.where(status: "draft").count,
          totalOrphanProjects:    GeoProject.where(user_id: nil).count,
          totalPoints:            GeoPoint.count
        }
      end
    end
  end
end
