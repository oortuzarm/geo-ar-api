class AddIsOnboardingPlanToPlans < ActiveRecord::Migration[7.2]
  def change
    add_column :plans, :is_onboarding_plan, :boolean, default: false, null: false
  end
end
