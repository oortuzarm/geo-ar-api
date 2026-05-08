class AddLocationToAnalyticsEvents < ActiveRecord::Migration[7.2]
  def change
    add_column :analytics_events, :latitude,  :float
    add_column :analytics_events, :longitude, :float
    add_column :analytics_events, :country,   :string
    add_column :analytics_events, :city,      :string
    add_column :analytics_events, :commune,   :string
  end
end
