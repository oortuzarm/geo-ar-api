class CreateSmartProxies < ActiveRecord::Migration[7.2]
  def change
    create_table :smart_proxies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, null: false, foreign_key: true, type: :uuid
      t.references :user,         null: false, foreign_key: true, type: :uuid
      t.string  :name,            null: false
      t.string  :slug,            null: false
      t.string  :destination_url, null: false
      t.string  :proxy_status,    null: false, default: "unknown"
      t.boolean :active,          null: false, default: true

      # Future: custom domain support (DNS/SSL verification not yet implemented)
      t.string :custom_domain
      t.string :domain_status, default: "pending"
      t.string :ssl_status,    default: "pending"

      t.timestamps
    end

    add_index :smart_proxies, %i[organization_id slug], unique: true
    add_index :smart_proxies, :active
    add_index :smart_proxies, :proxy_status
    add_index :smart_proxies, :custom_domain, unique: true, where: "custom_domain IS NOT NULL"
  end
end
