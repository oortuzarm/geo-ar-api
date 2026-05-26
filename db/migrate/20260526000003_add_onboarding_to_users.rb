class AddOnboardingToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :onboarding_completed,   :boolean, default: false, null: false
    add_column :users, :onboarding_category_id, :integer
    add_column :users, :onboarding_industry_id, :integer
    add_column :users, :onboarding_org_type_id, :integer
    add_column :users, :onboarding_org_size_id, :integer
    add_column :users, :onboarding_objective_id, :integer

    add_foreign_key :users, :onboarding_categories, column: :onboarding_category_id,  on_delete: :nullify
    add_foreign_key :users, :onboarding_options,    column: :onboarding_industry_id, on_delete: :nullify
    add_foreign_key :users, :onboarding_options,    column: :onboarding_org_type_id, on_delete: :nullify
    add_foreign_key :users, :onboarding_options,    column: :onboarding_org_size_id, on_delete: :nullify
    add_foreign_key :users, :onboarding_options,    column: :onboarding_objective_id, on_delete: :nullify

    # Mark all existing users as having completed onboarding — the flow is only
    # intended for new sign-ups after this migration runs.
    reversible do |dir|
      dir.up { execute "UPDATE users SET onboarding_completed = TRUE" }
    end
  end
end
