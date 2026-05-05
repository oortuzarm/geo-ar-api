class AddButtonTextToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :button_text, :string
  end
end
