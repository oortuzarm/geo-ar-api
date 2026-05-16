class SeedInitialPlans < ActiveRecord::Migration[7.2]
  # Seed the four canonical plans. Safe to re-run — uses find_or_create_by! on slug.
  # Prices are placeholders; edit via PATCH /api/admin/plans/:id before launching pricing.
  def up
    [
      {
        name:                    "Starter",
        slug:                    "starter",
        monthly_price:           9.00,
        annual_discount_percent: 20,
        location_limit:          10,
        has_trial:               true,
        trial_days:              14,
        is_visible:              true,
        is_recommended:          false,
        apply_to_existing_users: false,
        sort_order:              1,
        is_custom:               false
      },
      {
        name:                    "Business",
        slug:                    "business",
        monthly_price:           29.00,
        annual_discount_percent: 20,
        location_limit:          50,
        has_trial:               true,
        trial_days:              14,
        is_visible:              true,
        is_recommended:          true,
        apply_to_existing_users: false,
        sort_order:              2,
        is_custom:               false
      },
      {
        name:                    "Scale",
        slug:                    "scale",
        monthly_price:           79.00,
        annual_discount_percent: 20,
        location_limit:          250,
        has_trial:               true,
        trial_days:              14,
        is_visible:              true,
        is_recommended:          false,
        apply_to_existing_users: false,
        sort_order:              3,
        is_custom:               false
      },
      {
        name:                    "Enterprise",
        slug:                    "enterprise",
        monthly_price:           0.00,
        annual_discount_percent: 0,
        location_limit:          nil,
        has_trial:               false,
        trial_days:              nil,
        is_visible:              false,
        is_recommended:          false,
        apply_to_existing_users: false,
        sort_order:              4,
        is_custom:               true
      }
    ].each do |attrs|
      plan = Plan.find_or_initialize_by(slug: attrs[:slug])
      next if plan.persisted? # skip if already created by admin API

      # Compute yearly_price_computed manually (before_save won't fire in data migration)
      annual_base = attrs[:monthly_price] * 12
      discount    = annual_base * attrs[:annual_discount_percent] / 100.0
      attrs[:yearly_price_computed] = (annual_base - discount).round(2)

      plan.assign_attributes(attrs)
      plan.save!(validate: false)
    end
  end

  def down
    Plan.where(slug: %w[starter business scale enterprise]).destroy_all
  end
end
