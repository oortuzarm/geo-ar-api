class AddUserIdToGeoProjects < ActiveRecord::Migration[7.2]
  def change
    add_reference :geo_projects, :user, type: :uuid, foreign_key: true, null: true
  end
end
