class AddApiAccessToPlans < ActiveRecord::Migration[7.2]
  def change
    # api_access_enabled: true = the plan includes API access.
    # Default true so all existing plans retain access without disruption.
    add_column :plans, :api_access_enabled,    :boolean, null: false, default: true

    # api_credentials_limit: maximum number of active credentials per organization.
    # null = unlimited (Enterprise-style plans).
    add_column :plans, :api_credentials_limit, :integer, null: true
  end
end
