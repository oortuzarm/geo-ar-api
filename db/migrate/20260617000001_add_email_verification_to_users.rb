class AddEmailVerificationToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :email_verification_code,     :string
    add_column :users, :email_verification_sent_at,  :datetime
    add_column :users, :email_confirmed_at,           :datetime
  end
end
