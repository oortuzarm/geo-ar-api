# Smart Links events (smart_link_opened, smart_link_validation_failed with no
# inside candidate) do not have a specific geo_point. Making the column nullable
# allows these events to be recorded consistently in the shared analytics table.
class MakeAnalyticsEventsGeoPointNullable < ActiveRecord::Migration[7.2]
  def change
    change_column_null :analytics_events, :geo_point_id, true
  end
end
