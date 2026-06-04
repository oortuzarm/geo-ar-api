class CreateSmartLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :smart_links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    "user_id",         null: false
      t.uuid    "project_id",      null: false
      t.string  "name",            null: false
      t.string  "slug",            null: false
      t.string  "scope_type",      null: false, default: "project"
      t.string  "destination_type", null: false, default: "external_url"
      t.string  "destination_url"
      t.string  "status",          null: false, default: "active"
      t.jsonb   "ui_config",       null: false, default: {}
      t.timestamps
    end

    add_index :smart_links, :slug,       unique: true
    add_index :smart_links, :user_id
    add_index :smart_links, :project_id
    add_index :smart_links, :status

    add_foreign_key :smart_links, :users
    add_foreign_key :smart_links, :geo_projects, column: :project_id
  end
end
