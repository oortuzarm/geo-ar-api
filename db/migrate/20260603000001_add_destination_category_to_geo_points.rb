class AddDestinationCategoryToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :destination_category, :string
  end
end
