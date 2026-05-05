class CreateGeoPoints < ActiveRecord::Migration[7.2]
  def change
    create_table :geo_points, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :geo_project, null: false, foreign_key: true, type: :uuid

      t.string  :name,               null: false, default: "Nuevo punto"
      t.string  :lookiar_url,        null: false, default: ""
      t.float   :latitude,           null: false
      t.float   :longitude,          null: false
      t.integer :activation_radius,  null: false, default: 50
      # Store as URL in production. Base64 accepted temporarily.
      t.text    :image
      t.text    :description
      t.text    :instructions
      t.boolean :active,             null: false, default: true
      t.integer :order,              null: false, default: 0

      t.timestamps null: false
    end

    add_index :geo_points, %i[geo_project_id order]
  end
end
