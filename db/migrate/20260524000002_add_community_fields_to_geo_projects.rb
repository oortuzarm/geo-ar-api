class AddCommunityFieldsToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_projects, :community_enabled, :boolean, null: false, default: false
    add_column :geo_projects, :community_status,  :string,  null: false, default: "pending"
    add_index  :geo_projects, [:community_enabled, :community_status],
               name: "index_geo_projects_on_community"
  end
end
