class AddProjectLogoZoomToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_projects, :project_logo_zoom, :float
  end
end
