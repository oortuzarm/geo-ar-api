class AddSubscriptionFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_reference :users, :plan, type: :uuid, foreign_key: true, null: true

    add_column :users, :subscription_status,    :string,   null: false, default: "trial"
    add_column :users, :trial_starts_at,        :datetime, null: true
    add_column :users, :trial_ends_at,          :datetime, null: true
    add_column :users, :custom_location_limit,  :integer,  null: true

    add_index :users, :subscription_status
    add_index :users, :plan_id
  end
end
