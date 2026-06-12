class AddPointModeToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :point_mode, :string, default: "unlock", null: false
  end
end
