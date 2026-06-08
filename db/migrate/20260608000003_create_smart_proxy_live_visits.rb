class CreateSmartProxyLiveVisits < ActiveRecord::Migration[7.2]
  def change
    create_table :smart_proxy_live_visits, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :smart_proxy, null: false, foreign_key: true, type: :uuid
      t.string  :session_id,  null: false
      t.float   :lat,         null: false
      t.float   :lng,         null: false
      t.float   :accuracy
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    # One row per (proxy, session) — upserted on every heartbeat.
    add_index :smart_proxy_live_visits,
              %i[smart_proxy_id session_id],
              unique: true,
              name: "index_smart_proxy_live_visits_on_proxy_and_session"

    add_index :smart_proxy_live_visits, :last_seen_at
  end
end
