class AddPositionFlagsToAnalyticsEvents < ActiveRecord::Migration[7.2]
  def change
    add_column :analytics_events, :had_inside_position,  :boolean, default: false, null: false
    add_column :analytics_events, :had_outside_position, :boolean, default: false, null: false
  end
end
