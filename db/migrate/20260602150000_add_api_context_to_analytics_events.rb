class AddApiContextToAnalyticsEvents < ActiveRecord::Migration[7.2]
  def change
    add_column :analytics_events, :source,            :string
    add_column :analytics_events, :api_credential_id, :uuid
    add_column :analytics_events, :user_ref,          :string
    add_column :analytics_events, :context_metadata,  :jsonb
    add_column :analytics_events, :failure_reason,    :string

    add_index :analytics_events, :source
    add_index :analytics_events, :api_credential_id

    add_foreign_key :analytics_events, :api_credentials, column: :api_credential_id
  end
end
