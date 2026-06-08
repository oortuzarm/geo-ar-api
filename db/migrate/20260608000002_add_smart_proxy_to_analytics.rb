class AddSmartProxyToAnalytics < ActiveRecord::Migration[7.2]
  def change
    # Allow analytics events without a geo_project (Smart Proxy events have no project).
    change_column_null :analytics_events, :geo_project_id, true

    # Track which Smart Proxy generated the event.
    add_column :analytics_events, :smart_proxy_id, :uuid
    add_index  :analytics_events, :smart_proxy_id

    add_foreign_key :analytics_events, :smart_proxies,
                    column: :smart_proxy_id, on_delete: :nullify
  end
end
