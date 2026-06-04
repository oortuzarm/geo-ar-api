class AddOrganizationToGeoProjects < ActiveRecord::Migration[7.2]
  def up
    add_column :geo_projects, :organization_id, :uuid

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

    # Fail fast: never silently delete geo_projects or geo_points.
    # Projects with null user_id and projects from users with no membership
    # both require manual assignment before this migration can complete.
    orphan_count = GeoProject.where(organization_id: nil).count
    if orphan_count > 0
      raise "MIGRATION BLOCKED: #{orphan_count} geo_project(s) could not be assigned to an " \
            "organization. This includes projects with no user_id and projects whose owner " \
            "has no organization membership.\n\n" \
            "  -- Projects with no user:\n" \
            "  SELECT id, title FROM geo_projects WHERE user_id IS NULL;\n\n" \
            "  -- Projects from users without organizations:\n" \
            "  SELECT gp.id, gp.title, gp.user_id\n" \
            "  FROM geo_projects gp\n" \
            "  LEFT JOIN memberships m ON m.user_id = gp.user_id\n" \
            "  WHERE gp.user_id IS NOT NULL AND m.id IS NULL;\n\n" \
            "Assign a user and organization to each affected project, then retry."
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
