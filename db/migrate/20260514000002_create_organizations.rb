class CreateOrganizations < ActiveRecord::Migration[7.2]
  def change
    create_table :organizations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
