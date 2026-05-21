class AddDemoProjectIdToTemporaryPreviews < ActiveRecord::Migration[7.2]
  def change
    add_column :temporary_previews, :demo_project_id, :string, null: true
    add_index  :temporary_previews, :demo_project_id
  end
end
