class CreateTemporaryPreviews < ActiveRecord::Migration[7.2]
  def change
    create_table :temporary_previews, id: :uuid do |t|
      t.string   :token,      null: false
      t.jsonb    :payload,    null: false, default: {}
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :temporary_previews, :token,      unique: true
    add_index :temporary_previews, :expires_at
  end
end
