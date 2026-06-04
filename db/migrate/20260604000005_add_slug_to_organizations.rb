class AddSlugToOrganizations < ActiveRecord::Migration[7.2]
  def up
    add_column :organizations, :slug, :string

    Organization.reset_column_information

    # Fail fast: blank names produce invalid slugs. Require manual fix before deploy.
    blank_names = Organization.where("name IS NULL OR TRIM(name) = ''").count
    if blank_names > 0
      raise "MIGRATION BLOCKED: #{blank_names} organization(s) have a nil or blank name. " \
            "Fix the data before running this migration.\n\n" \
            "  -- Find affected records:\n" \
            "  SELECT id, name FROM organizations WHERE name IS NULL OR TRIM(name) = '';"
    end

    Organization.where(slug: nil).find_each do |org|
      base = org.name.parameterize
      slug = base
      counter = 1
      while Organization.where.not(id: org.id).exists?(slug: slug)
        slug = "#{base}-#{counter}"
        counter += 1
      end
      org.update_column(:slug, slug)
    end

    # Fail fast: verify no slug ended up blank after parameterize.
    blank_slugs = Organization.where("slug IS NULL OR slug = ''").count
    if blank_slugs > 0
      raise "MIGRATION BLOCKED: #{blank_slugs} organization(s) produced a blank slug after " \
            "parameterize. Check organization names and retry.\n\n" \
            "  SELECT id, name FROM organizations WHERE slug IS NULL OR slug = '';"
    end

    change_column_null :organizations, :slug, false
    add_index :organizations, :slug, unique: true
  end

  def down
    remove_index  :organizations, :slug
    remove_column :organizations, :slug
  end
end
