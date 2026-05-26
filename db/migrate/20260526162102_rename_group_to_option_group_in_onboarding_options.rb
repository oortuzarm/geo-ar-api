class RenameGroupToOptionGroupInOnboardingOptions < ActiveRecord::Migration[7.2]
  def change
    if column_exists?(:onboarding_options, :group) &&
       !column_exists?(:onboarding_options, :option_group)

      rename_column :onboarding_options, :group, :option_group
    end
  end
end