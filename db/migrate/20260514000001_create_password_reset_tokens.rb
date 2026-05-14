class CreatePasswordResetTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :password_reset_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string   :token_digest, null: false
      t.datetime :expires_at,   null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :password_reset_tokens, :token_digest, unique: true
  end
end
