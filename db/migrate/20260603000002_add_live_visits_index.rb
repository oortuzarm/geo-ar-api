class AddLiveVisitsIndex < ActiveRecord::Migration[7.2]
  def change
    add_index :geo_point_live_visits,
              %i[geo_point_id inside_radius last_seen_at],
              name: "idx_live_visits_active"
  end
end
