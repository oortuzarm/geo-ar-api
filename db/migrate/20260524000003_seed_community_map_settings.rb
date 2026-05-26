class SeedCommunityMapSettings < ActiveRecord::Migration[7.2]
  DEFAULTS = [
    [ "community_map_enabled",             "false" ],
    [ "community_map_disabled_title",      "Mapa comunitario próximamente" ],
    [ "community_map_disabled_description",
     "Estamos preparando esta función para que puedas descubrir experiencias compartidas por categoría." ]
  ].freeze

  def up
    DEFAULTS.each do |key, value|
      execute <<~SQL
        INSERT INTO site_configs (key, value, created_at, updated_at)
        VALUES (#{sanitize(key)}, #{sanitize(value)}, NOW(), NOW())
        ON CONFLICT (key) DO NOTHING
      SQL
    end
  end

  def down
    keys = DEFAULTS.map { |k, _| sanitize(k) }.join(", ")
    execute "DELETE FROM site_configs WHERE key IN (#{keys})"
  end

  private

  def sanitize(val)
    ActiveRecord::Base.connection.quote(val)
  end
end
