class CreateApiCredentials < ActiveRecord::Migration[7.2]
  def change
    create_table :api_credentials, id: :uuid do |t|
      t.references :organization, null: false, foreign_key: true, type: :uuid
      t.string :name,                    null: false
      t.string :key_public,              null: false
      t.string :key_secret_digest,       null: false
      t.string :previous_key_secret_digest
      t.datetime :previous_key_expires_at
      t.string :scopes, array: true,     null: false, default: []
      t.string :status,                  null: false, default: "active"
      t.datetime :expires_at
      t.datetime :last_used_at
      t.uuid :created_by_user_id
      t.datetime :revoked_at
      t.uuid :revoked_by_user_id
      t.timestamps
    end

    add_index :api_credentials, :key_public, unique: true
    add_index :api_credentials, :status

    add_foreign_key :api_credentials, :users, column: :created_by_user_id
    add_foreign_key :api_credentials, :users, column: :revoked_by_user_id
  end
end
