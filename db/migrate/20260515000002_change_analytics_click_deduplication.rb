class ChangeAnalyticsClickDeduplication < ActiveRecord::Migration[7.2]
  def up
    # Drop the project-wide unique index that blocks all repeat point_click events.
    remove_index :analytics_events, name: "idx_analytics_events_uniqueness"

    # Re-add uniqueness only for radius_enter — 1 entry per (session, project, point, day).
    # point_click events are intentionally NOT covered: every real click must be counted.
    add_index :analytics_events,
              %i[geo_project_id geo_point_id event_type session_id event_date],
              unique: true,
              where:  "event_type = 'radius_enter'",
              name:   "idx_analytics_events_radius_enter_uniqueness"
  end

  def down
    remove_index :analytics_events, name: "idx_analytics_events_radius_enter_uniqueness"

    add_index :analytics_events,
              %i[geo_project_id geo_point_id event_type session_id event_date],
              unique: true,
              name:   "idx_analytics_events_uniqueness"
  end
end
