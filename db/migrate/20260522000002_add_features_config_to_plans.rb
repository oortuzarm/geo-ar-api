class AddFeaturesConfigToPlans < ActiveRecord::Migration[7.2]
  def up
    add_column :plans, :features_config, :jsonb, null: false, default: {}

    # Local variables avoid "already initialized constant" warnings on double-load.
    plan_seed_configs = {
      "starter" => {
        "content_types"         => %w[url video audio file],
        "availability_schedule" => false,
        "availability_quota"    => false,
        "analytics"             => false,
        "members"               => false
      }
      # business, scale, enterprise — full access
    }.freeze

    full_access = {
      "content_types"         => %w[url video audio file],
      "availability_schedule" => true,
      "availability_quota"    => true,
      "analytics"             => true,
      "members"               => true
    }.freeze

    Plan.find_each do |plan|
      config = plan_seed_configs.fetch(plan.slug, full_access)
      plan.update_columns(features_config: config)
    end
  end

  def down
    remove_column :plans, :features_config
  end
end
