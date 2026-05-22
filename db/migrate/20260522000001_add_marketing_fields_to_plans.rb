class AddMarketingFieldsToPlans < ActiveRecord::Migration[7.2]
  def change
    add_column :plans, :public_description, :text,   null: true
    add_column :plans, :features,           :jsonb,  null: false, default: []
    add_column :plans, :cta_text,           :string, null: true
    add_column :plans, :cta_url,            :string, null: true
  end
end
