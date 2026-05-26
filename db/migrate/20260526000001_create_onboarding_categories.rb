class CreateOnboardingCategories < ActiveRecord::Migration[7.2]
  def change
    create_table :onboarding_categories do |t|
      t.string  :name,        null: false
      t.string  :slug,        null: false
      t.string  :description
      t.string  :icon_name
      t.integer :position,    null: false, default: 0
      t.boolean :active,      null: false, default: true
      t.integer :usage_count, null: false, default: 0

      t.timestamps
    end

    add_index :onboarding_categories, :slug,     unique: true
    add_index :onboarding_categories, :active
    add_index :onboarding_categories, :position
  end
end
