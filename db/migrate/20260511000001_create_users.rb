class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email,           null: false
      t.string :password_digest, null: false
      t.string :role,            null: false, default: "user"
      t.string :status,          null: false, default: "active"
      t.timestamps
    end

    add_index :users, :email, unique: true
  end
end
