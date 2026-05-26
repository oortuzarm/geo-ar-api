class RenameGroupToOptionGroupInOnboardingOptions < ActiveRecord::Migration[7.2]
  def change
    rename_column :onboarding_options, :group, :option_group

    if index_name_exists?(:onboarding_options, "index_onboarding_options_on_group")
      rename_index :onboarding_options,
                   "index_onboarding_options_on_group",
                   "index_onboarding_options_on_option_group"
    end

    if index_name_exists?(:onboarding_options, "index_onboarding_options_on_group_and_slug")
      rename_index :onboarding_options,
                   "index_onboarding_options_on_group_and_slug",
                   "index_onboarding_options_on_option_group_and_slug"
    end
  end
end