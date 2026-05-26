class CreateOnboardingOptions < ActiveRecord::Migration[7.2]
  def change
    create_table :onboarding_options do |t|
      t.string  :option_group, null: false   # 'industry' | 'org_type' | 'org_size' | 'objective'
      t.string  :name,         null: false
      t.string  :slug,         null: false
      t.integer :position,     null: false, default: 0
      t.boolean :active,       null: false, default: true
      t.integer :usage_count,  null: false, default: 0

      t.timestamps
    end

    add_index :onboarding_options, [ :option_group, :slug ], unique: true
    add_index :onboarding_options, :option_group
    add_index :onboarding_options, :active
  end
end
