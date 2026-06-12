class AddSocialLinksToGeoPoints < ActiveRecord::Migration[7.1]
  def change
    add_column :geo_points, :social_links, :jsonb, default: {}
  end
end
