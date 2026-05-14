class CreateInvitations < ActiveRecord::Migration[7.2]
  def change
    create_table :invitations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :invited_by,   type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string     :email,        null: false
      t.string     :role,         null: false
      t.string     :token_digest, null: false
      t.datetime   :expires_at,   null: false
      t.datetime   :accepted_at
      t.timestamps
    end

    add_index :invitations, :token_digest, unique: true
    add_index :invitations, %i[organization_id email]
  end
end
