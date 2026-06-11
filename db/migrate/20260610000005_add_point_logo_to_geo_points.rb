class AddPointLogoToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :point_logo_url,        :string
    add_column :geo_points, :point_logo_zoom,        :float
    add_column :geo_points, :point_logo_position_x,  :float
    add_column :geo_points, :point_logo_position_y,  :float
  end
end
