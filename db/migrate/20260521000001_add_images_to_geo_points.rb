class AddImagesToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :images, :jsonb, null: true, default: nil
  end
end
