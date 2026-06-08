class AddCompatibilityToSmartProxies < ActiveRecord::Migration[7.2]
  def change
    add_column :smart_proxies, :compatibility_status,     :string,   default: "pending", null: false
    add_column :smart_proxies, :compatibility_score,      :integer,  default: 0,         null: false
    add_column :smart_proxies, :compatibility_report,     :jsonb,    default: {}
    add_column :smart_proxies, :compatibility_checked_at, :datetime

    add_index :smart_proxies, :compatibility_status
  end
end
