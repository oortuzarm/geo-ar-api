class AddPolygonToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :activation_mode,    :string, default: "radius", null: false
    add_column :geo_points, :activation_polygon, :jsonb,  default: nil,      null: true

    add_index :geo_points, :activation_mode
  end
end
