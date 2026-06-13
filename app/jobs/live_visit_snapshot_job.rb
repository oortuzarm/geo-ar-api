class LiveVisitSnapshotJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current

    GeoProject.where(status: "active").find_each do |project|
      snapshot_project(project, now)
    rescue => e
      Rails.logger.error "[LiveVisitSnapshotJob] project #{project.id} failed: #{e.class}: #{e.message}"
    end
  end

  private

  def snapshot_project(project, now)
    counts_by_point = GeoPointLiveVisit
      .where(geo_project_id: project.id)
      .inside_radius
      .active_now
      .group(:geo_point_id)
      .count

    project_total = counts_by_point.values.sum

    rows = counts_by_point.map do |point_id, count|
      { geo_project_id: project.id, geo_point_id: point_id, active_count: count, sampled_at: now }
    end

    # Always include a project-level row (geo_point_id: nil), even when count is
    # zero, so last_hour_delta_percent can distinguish "no data" from "empty."
    rows << { geo_project_id: project.id, geo_point_id: nil, active_count: project_total, sampled_at: now }

    LiveVisitSnapshot.insert_all(rows)
  end
end
