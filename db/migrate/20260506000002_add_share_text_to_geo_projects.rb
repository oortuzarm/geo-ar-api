class AddShareTextToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_projects, :share_text, :text
  end
end
