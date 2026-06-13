class CreateLiveVisitSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :live_visit_snapshots, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid     :geo_project_id, null: false
      t.uuid     :geo_point_id              # NULL = project-level snapshot
      t.integer  :active_count,   null: false
      t.datetime :sampled_at,     null: false
    end

    # Primary lookup: filter by project + point, range scan on time.
    add_index :live_visit_snapshots,
              %i[geo_project_id geo_point_id sampled_at],
              name: "idx_live_visit_snapshots_lookup"

    # Cleanup: DELETE WHERE sampled_at < 7.days.ago.
    add_index :live_visit_snapshots, :sampled_at,
              name: "idx_live_visit_snapshots_cleanup"
  end
end
