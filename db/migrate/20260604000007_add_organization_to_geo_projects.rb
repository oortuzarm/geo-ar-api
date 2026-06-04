# ⚠️  DESTRUCTIVE OPERATION — explicitly accepted by product decision.
#
# GeoProjects that cannot be assigned to an Organization are deleted along
# with all their dependent data. This is safe because Ubyca has not launched
# to the market and these are historical/test records with no real customers.
#
# Decision recorded: 2026-06-04.
# Deletion is logged with project ids and titles before any rows are removed.
class AddOrganizationToGeoProjects < ActiveRecord::Migration[7.2]
  def up
    add_column :geo_projects, :organization_id, :uuid
    GeoProject.reset_column_information

    # Backfill: assign each project the first organization its owner belongs to.
    execute <<~SQL
      UPDATE geo_projects gp
      SET organization_id = (
        SELECT organization_id FROM memberships
        WHERE user_id = gp.user_id
        ORDER BY created_at ASC
        LIMIT 1
      )
      WHERE gp.user_id IS NOT NULL
    SQL

    # ── Orphan cleanup ────────────────────────────────────────────────────────
    # Projects with user_id NULL or owners with no membership cannot be
    # assigned to any organization. Per product decision they are deleted.

    orphans = GeoProject.where(organization_id: nil)
                        .select(:id, :title, :user_id)
                        .order(:created_at)
                        .to_a

    if orphans.any?
      orphan_ids = orphans.map(&:id)
      point_ids  = GeoPoint.where(geo_project_id: orphan_ids).pluck(:id)
      link_ids   = SmartLink.where(project_id:    orphan_ids).pluck(:id)

      say "=" * 65
      say "⚠️  DELETING #{orphans.size} orphaned GeoProject(s):"
      orphans.each do |p|
        say "    [#{p.id}] #{p.title.inspect}  (user_id: #{p.user_id.inspect})"
      end
      say "    #{point_ids.size} geo_points will also be removed."
      say "=" * 65

      # ── 1. geo_point_live_visits ─────────────────────────────────────────
      # FK: geo_point_id → geo_points  AND  geo_project_id → geo_projects
      # Must be deleted before geo_points and before geo_projects.
      # Filter by both FKs: data inconsistencies (e.g. test records) can leave
      # live_visits whose geo_point_id is not in point_ids but whose
      # geo_project_id still points at an orphan project.
      n = GeoPointLiveVisit
            .where(geo_point_id: point_ids)
            .or(GeoPointLiveVisit.where(geo_project_id: orphan_ids))
            .delete_all
      say "  [1/6] Deleted #{n} geo_point_live_visit(s)"

      # ── 2. smart_link_geo_points ─────────────────────────────────────────
      # FK: geo_point_id → geo_points  AND  smart_link_id → smart_links
      # Must be deleted before geo_points and before smart_links.
      n = SmartLinkGeoPoint
            .where(geo_point_id: point_ids)
            .or(SmartLinkGeoPoint.where(smart_link_id: link_ids))
            .delete_all
      say "  [2/6] Deleted #{n} smart_link_geo_point(s)"

      # ── 3. analytics_events ──────────────────────────────────────────────
      # No FK constraint to geo_projects/geo_points in current schema,
      # but deleted for data hygiene.
      n = AnalyticsEvent.where(geo_project_id: orphan_ids).delete_all
      say "  [3/6] Deleted #{n} analytics_event(s)"

      # ── 4. geo_points ────────────────────────────────────────────────────
      # FK: geo_project_id → geo_projects
      # live_visits and smart_link_geo_points already removed above.
      n = GeoPoint.where(geo_project_id: orphan_ids).delete_all
      say "  [4/6] Deleted #{n} geo_point(s)"

      # ── 5. smart_links ───────────────────────────────────────────────────
      # FK: project_id → geo_projects
      # smart_link_geo_points already removed above.
      n = SmartLink.where(project_id: orphan_ids).delete_all
      say "  [5/6] Deleted #{n} smart_link(s)"

      # ── 6. geo_projects ──────────────────────────────────────────────────
      # All dependent rows have been removed; safe to delete the projects.
      GeoProject.where(id: orphan_ids).delete_all
      say "  [6/6] Deleted #{orphans.size} geo_project(s)"
      say "=" * 65
    end

    # Defensive check: verify cleanup is complete before adding NOT NULL.
    remaining = GeoProject.where(organization_id: nil).count
    if remaining > 0
      raise "MIGRATION ERROR: #{remaining} geo_project(s) still have no organization_id " \
            "after cleanup. This should not happen — investigate before retrying."
    end

    change_column_null :geo_projects, :organization_id, false
    add_index    :geo_projects, :organization_id
    add_foreign_key :geo_projects, :organizations
  end

  def down
    remove_foreign_key :geo_projects, :organizations
    remove_index  :geo_projects, :organization_id
    remove_column :geo_projects, :organization_id
  end
end
