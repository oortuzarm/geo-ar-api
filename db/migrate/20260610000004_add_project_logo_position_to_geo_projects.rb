class AddProjectLogoPositionToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_projects, :project_logo_position_x, :float
    add_column :geo_projects, :project_logo_position_y, :float
  end
end
