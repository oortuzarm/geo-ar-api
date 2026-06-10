class CreateProjectLiveVisits < ActiveRecord::Migration[7.2]
  def change
    create_table :project_live_visits, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :geo_project_id, null: false
      t.string  :session_id,     null: false
      t.float   :lat,            null: false
      t.float   :lng,            null: false
      t.float   :accuracy
      t.datetime :last_seen_at,  null: false
      t.timestamps
    end

    # One active row per session per project (upsert key).
    add_index :project_live_visits, %i[geo_project_id session_id],
              unique: true,
              name: "index_project_live_visits_on_project_and_session"

    # Fast active-window queries: WHERE last_seen_at >= 45.seconds.ago
    add_index :project_live_visits, %i[geo_project_id last_seen_at],
              name: "idx_project_live_visits_active"

    # One project_location AnalyticsEvent per (session, project, day).
    add_index :analytics_events, %i[geo_project_id session_id event_date],
              unique: true,
              where: "event_type = 'project_location'",
              name: "idx_analytics_events_project_location_uniqueness"
  end
end
