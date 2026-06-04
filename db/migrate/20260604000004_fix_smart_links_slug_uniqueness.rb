class FixSmartLinksSlugUniqueness < ActiveRecord::Migration[7.2]
  def change
    remove_index :smart_links, :slug
    add_index :smart_links, %i[user_id slug], unique: true,
              name: "index_smart_links_on_user_id_and_slug"
  end
end
