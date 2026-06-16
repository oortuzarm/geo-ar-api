class AddFeaturedToGeoPoints < ActiveRecord::Migration[7.1]
  def change
    add_column :geo_points, :featured, :boolean, default: false, null: false
  end
end
