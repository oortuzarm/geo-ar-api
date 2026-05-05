class CreateGeoProjects < ActiveRecord::Migration[7.2]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :geo_projects, id: :uuid, default: "gen_random_uuid()" do |t|
      t.string  :title,       null: false, default: "Nuevo proyecto GPS"
      t.string  :subtitle
      t.text    :description
      # Store as URL in production (S3 / Cloudflare R2). Base64 accepted temporarily.
      t.text    :cover_image
      t.text    :how_to_get
      t.string  :status,      null: false, default: "draft"

      t.timestamps null: false
    end

    add_index :geo_projects, :status
  end
end
