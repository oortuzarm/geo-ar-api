class AddContentFieldsToGeoPoints < ActiveRecord::Migration[7.2]
  def up
    add_column :geo_points, :content_type, :string, null: false, default: "url"
    add_column :geo_points, :content_data, :jsonb,  null: false, default: {}

    # Migrate all existing rows: copy lookiar_url into content_data.url
    execute <<~SQL
      UPDATE geo_points
      SET content_data = jsonb_build_object('url', COALESCE(NULLIF(lookiar_url, ''), ''))
      WHERE content_data = '{}'::jsonb
    SQL
  end

  def down
    remove_column :geo_points, :content_data
    remove_column :geo_points, :content_type
  end
end
