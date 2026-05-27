class AddDwellTimeToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :requires_dwell_time, :boolean, default: false, null: false
    add_column :geo_points, :dwell_time_seconds,  :integer, default: 0,     null: false
  end
end
