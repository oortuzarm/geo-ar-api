class CreateSmartLinkGeoPoints < ActiveRecord::Migration[7.2]
  def change
    create_table :smart_link_geo_points, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "smart_link_id", null: false
      t.uuid "geo_point_id",  null: false
      t.timestamps
    end

    add_index :smart_link_geo_points, %i[smart_link_id geo_point_id], unique: true
    add_index :smart_link_geo_points, :geo_point_id

    add_foreign_key :smart_link_geo_points, :smart_links
    add_foreign_key :smart_link_geo_points, :geo_points
  end
end
