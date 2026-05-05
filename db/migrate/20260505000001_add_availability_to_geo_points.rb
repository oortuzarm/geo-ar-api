class AddAvailabilityToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :availability, :jsonb, default: {}, null: false
  end
end
