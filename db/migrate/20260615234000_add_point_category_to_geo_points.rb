class AddPointCategoryToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :point_category, :string
  end
end
