class UpdateSmartLinksToOrganization < ActiveRecord::Migration[7.2]
  def up
    add_column :smart_links, :organization_id, :uuid

    execute <<~SQL
      UPDATE smart_links sl
      SET organization_id = (
        SELECT organization_id FROM memberships
        WHERE user_id = sl.user_id
        ORDER BY created_at ASC
        LIMIT 1
      )
    SQL

    # Fail fast: never silently delete smart_links. Require human review.
    orphan_count = SmartLink.where(organization_id: nil).count
    if orphan_count > 0
      raise "MIGRATION BLOCKED: #{orphan_count} smart_link(s) could not be assigned to an " \
            "organization. Their owner users have no organization membership.\n\n" \
            "  -- Find affected records:\n" \
            "  SELECT sl.id, sl.user_id, sl.name\n" \
            "  FROM smart_links sl\n" \
            "  LEFT JOIN memberships m ON m.user_id = sl.user_id\n" \
            "  WHERE m.id IS NULL;\n\n" \
            "Assign the affected users to an organization, then retry."
    end

    change_column_null :smart_links, :organization_id, false

    remove_index  :smart_links, name: "index_smart_links_on_user_id_and_slug"
    add_index     :smart_links, %i[organization_id slug], unique: true,
                  name: "index_smart_links_on_organization_id_and_slug"
    add_foreign_key :smart_links, :organizations
  end

  def down
    remove_foreign_key :smart_links, :organizations
    remove_index  :smart_links, name: "index_smart_links_on_organization_id_and_slug"
    add_index     :smart_links, %i[user_id slug], unique: true,
                  name: "index_smart_links_on_user_id_and_slug"
    change_column_null :smart_links, :organization_id, true
    remove_column :smart_links, :organization_id
  end
end
