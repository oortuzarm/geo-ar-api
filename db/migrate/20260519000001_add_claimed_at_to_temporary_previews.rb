class AddClaimedAtToTemporaryPreviews < ActiveRecord::Migration[7.2]
  def change
    add_column :temporary_previews, :claimed_at, :datetime, null: true
    add_index  :temporary_previews, :claimed_at
  end
end
