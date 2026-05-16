class CreatePlans < ActiveRecord::Migration[7.2]
  def change
    create_table :plans, id: :uuid do |t|
      t.string  :name,                     null: false
      t.string  :slug,                     null: false
      t.decimal :monthly_price,            null: false, precision: 10, scale: 2
      t.integer :annual_discount_percent,  null: false, default: 0
      t.decimal :yearly_price_computed,    null: true,  precision: 10, scale: 2
      t.integer :location_limit,           null: true   # null = unlimited
      t.boolean :has_trial,                null: false, default: false
      t.integer :trial_days,               null: true
      t.boolean :is_visible,               null: false, default: true
      t.boolean :is_recommended,           null: false, default: false
      t.boolean :apply_to_existing_users,  null: false, default: false
      t.integer :sort_order,               null: false, default: 0
      t.boolean :is_custom,               null: false, default: false

      t.timestamps
    end

    add_index :plans, :slug,       unique: true
    add_index :plans, :is_visible
    add_index :plans, :sort_order
  end
end
