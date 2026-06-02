class CreateIdempotencyKeys < ActiveRecord::Migration[7.2]
  def change
    create_table :idempotency_keys, id: :uuid do |t|
      t.uuid     :api_credential_id, null: false
      t.string   :idempotency_key,   null: false
      t.string   :endpoint,          null: false
      t.integer  :response_status
      t.text     :response_body
      t.datetime :expires_at,        null: false
      t.datetime :locked_at
      t.timestamps
    end

    add_index :idempotency_keys, %i[api_credential_id idempotency_key], unique: true, name: "idx_idempotency_keys_on_credential_and_key"
    add_index :idempotency_keys, :expires_at

    add_foreign_key :idempotency_keys, :api_credentials
  end
end
