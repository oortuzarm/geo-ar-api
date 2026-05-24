class CreateSiteConfigs < ActiveRecord::Migration[7.2]
  def up
    create_table :site_configs do |t|
      t.string :key,   null: false
      t.string :value, null: false
      t.timestamps
    end
    add_index :site_configs, :key, unique: true

    execute <<~SQL
      INSERT INTO site_configs (key, value, created_at, updated_at)
      VALUES ('register_trial_days', '14', NOW(), NOW())
    SQL
  end

  def down
    drop_table :site_configs
  end
end
