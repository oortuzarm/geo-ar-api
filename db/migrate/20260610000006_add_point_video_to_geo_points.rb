class AddPointVideoToGeoPoints < ActiveRecord::Migration[7.2]
  def change
    add_column :geo_points, :point_video_url,  :string
    add_column :geo_points, :point_video_type, :string
  end
end
