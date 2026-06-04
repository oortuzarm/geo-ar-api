class AddSlugToOrganizations < ActiveRecord::Migration[7.2]
  def up
    add_column :organizations, :slug, :string

    Organization.reset_column_information
    Organization.where(slug: nil).find_each do |org|
      base = org.name.to_s.parameterize
      slug = base
      counter = 1
      while Organization.where.not(id: org.id).exists?(slug: slug)
        slug = "#{base}-#{counter}"
        counter += 1
      end
      org.update_column(:slug, slug)
    end

    change_column_null :organizations, :slug, false
    add_index :organizations, :slug, unique: true
  end

  def down
    remove_index  :organizations, :slug
    remove_column :organizations, :slug
  end
end
