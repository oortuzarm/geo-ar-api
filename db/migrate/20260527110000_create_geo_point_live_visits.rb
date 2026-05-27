class CreateGeoPointLiveVisits < ActiveRecord::Migration[7.2]
  def change
    create_table :geo_point_live_visits, id: :uuid do |t|
      t.uuid     :geo_project_id, null: false
      t.uuid     :geo_point_id,   null: false
      t.string   :session_id,     null: false
      t.float    :lat,            null: false
      t.float    :lng,            null: false
      t.float    :accuracy
      t.boolean  :inside_radius,  null: false, default: false
      t.datetime :last_seen_at,   null: false

      t.timestamps
    end

    add_foreign_key :geo_point_live_visits, :geo_projects
    add_foreign_key :geo_point_live_visits, :geo_points

    # One row per (point, session) — upserted on each heartbeat.
    add_index :geo_point_live_visits, %i[geo_point_id session_id], unique: true

    add_index :geo_point_live_visits, :geo_project_id
    add_index :geo_point_live_visits, :last_seen_at
    add_index :geo_point_live_visits, :inside_radius
  end
end
