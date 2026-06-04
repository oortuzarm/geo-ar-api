class UpdateSmartLinksToOrganization < ActiveRecord::Migration[7.2]
  def up
    add_column :smart_links, :organization_id, :uuid

    # Backfill: assign each smart_link the user's first organization.
    execute <<~SQL
      UPDATE smart_links sl
      SET organization_id = (
        SELECT organization_id FROM memberships
        WHERE user_id = sl.user_id
        ORDER BY created_at ASC
        LIMIT 1
      )
    SQL

    # Drop orphaned records (users with no organization).
    execute "DELETE FROM smart_link_geo_points WHERE smart_link_id IN (SELECT id FROM smart_links WHERE organization_id IS NULL)"
    execute "DELETE FROM smart_links WHERE organization_id IS NULL"

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
