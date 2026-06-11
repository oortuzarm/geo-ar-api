class CreateGeoPointCollections < ActiveRecord::Migration[7.2]
  def change
    create_table :geo_point_collections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :geo_point,
                   null: false,
                   type: :uuid,
                   foreign_key: { on_delete: :cascade }
      t.references :required_geo_point,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :geo_points, on_delete: :cascade }
      t.timestamps
    end

    add_index :geo_point_collections,
              %i[geo_point_id required_geo_point_id],
              unique: true,
              name: "idx_geo_point_collections_unique"
  end
end
