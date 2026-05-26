class AddProfileFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :first_name,           :string
    add_column :users, :last_name,            :string
    add_column :users, :company,              :string
    add_column :users, :job_title,            :string
    add_column :users, :country,              :string
    add_column :users, :force_password_change, :boolean, default: false, null: false
  end
end
