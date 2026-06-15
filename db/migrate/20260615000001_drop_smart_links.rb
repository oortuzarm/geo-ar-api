class DropSmartLinks < ActiveRecord::Migration[7.2]
  def up
    drop_table :smart_link_geo_points
    drop_table :smart_links
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Smart Links was removed intentionally. Restore from a backup if needed."
  end
end
