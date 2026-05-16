class AddSubscriptionFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    # add_reference creates index_users_on_plan_id automatically via index: true (default).
    # Guard the whole reference block so a partial previous run doesn't double-add it.
    unless column_exists?(:users, :plan_id)
      add_reference :users, :plan, type: :uuid, foreign_key: true, null: true
    end

    add_column :users, :subscription_status,   :string,   null: false, default: "trial" unless column_exists?(:users, :subscription_status)
    add_column :users, :trial_starts_at,        :datetime, null: true                   unless column_exists?(:users, :trial_starts_at)
    add_column :users, :trial_ends_at,          :datetime, null: true                   unless column_exists?(:users, :trial_ends_at)
    add_column :users, :custom_location_limit,  :integer,  null: true                   unless column_exists?(:users, :custom_location_limit)

    # add_reference already created index_users_on_plan_id — do NOT add it again.
    unless index_exists?(:users, :subscription_status)
      add_index :users, :subscription_status
    end
  end
end
