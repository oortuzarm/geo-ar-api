class CreateAnalyticsEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :analytics_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid   :geo_project_id, null: false
      t.uuid   :geo_point_id,   null: false
      t.string :event_type,     null: false
      t.string :session_id,     null: false
      t.date   :event_date,     null: false
      t.timestamps
    end

    # Enforces one event per point+type+session+day at DB level
    add_index :analytics_events,
              %i[geo_project_id geo_point_id event_type session_id event_date],
              unique: true,
              name: "idx_analytics_events_uniqueness"

    add_index :analytics_events, :geo_project_id
  end
end
