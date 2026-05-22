class AddFeaturesToPlans < ActiveRecord::Migration[7.2]
  # Default entitlements applied to plans that existed before this migration.
  PLAN_SEED_CONFIGS = {
    "starter" => {
      "content_types"         => %w[url video audio file],
      "availability_schedule" => false,
      "availability_quota"    => false,
      "analytics"             => false,
      "members"               => false,
    },
    # business, scale, enterprise — full access
  }.freeze

  FULL_ACCESS = {
    "content_types"         => %w[url video audio file],
    "availability_schedule" => true,
    "availability_quota"    => true,
    "analytics"             => true,
    "members"               => true,
  }.freeze

  def up
    add_column :plans, :features_config, :jsonb, null: false, default: {}

    Plan.find_each do |plan|
      config = PLAN_SEED_CONFIGS.fetch(plan.slug, FULL_ACCESS)
      plan.update_columns(features_config: config)
    end
  end

  def down
    remove_column :plans, :features_config
  end
end
