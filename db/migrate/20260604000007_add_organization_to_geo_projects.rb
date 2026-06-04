class AddOrganizationToGeoProjects < ActiveRecord::Migration[7.2]
  def up
    add_column :geo_projects, :organization_id, :uuid

    # Backfill from user→memberships: each project inherits its owner's first org.
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

    # Remove projects that cannot be assigned to any organization (no user / no membership).
    # In production this count should be zero; if not, the data must be reviewed.
    orphan_count = GeoProject.where(organization_id: nil).count
    if orphan_count > 0
      Rails.logger.warn "[MIGRATION] #{orphan_count} geo_project(s) without organization — deleting."
      GeoPoint.where(geo_project_id: GeoProject.where(organization_id: nil).select(:id)).delete_all
      GeoProject.where(organization_id: nil).delete_all
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
