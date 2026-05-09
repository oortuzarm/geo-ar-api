class AddPublicInitialViewToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_projects, :public_initial_view_mode,  :string,  default: "fit_points"
    add_column :geo_projects, :public_initial_center_lat, :decimal, precision: 10, scale: 6
    add_column :geo_projects, :public_initial_center_lng, :decimal, precision: 10, scale: 6
    add_column :geo_projects, :public_initial_zoom,       :integer
  end
end
