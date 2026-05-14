class SeedOrganizationsForExistingUsers < ActiveRecord::Migration[7.2]
  # Creates a default Organization + owner Membership for every user that
  # doesn't have one yet. Safe to re-run (skips users that already have a membership).
  def up
    user_ids = execute(
      "SELECT id FROM users WHERE id NOT IN (SELECT DISTINCT user_id FROM memberships)"
    ).map { |r| r["id"] }

    user_ids.each do |user_id|
      org_id        = SecureRandom.uuid
      membership_id = SecureRandom.uuid

      execute <<~SQL
        INSERT INTO organizations (id, name, created_at, updated_at)
        VALUES ('#{org_id}', 'Mi organización', NOW(), NOW())
      SQL

      execute <<~SQL
        INSERT INTO memberships (id, user_id, organization_id, role, created_at, updated_at)
        VALUES ('#{membership_id}', '#{user_id}', '#{org_id}', 'owner', NOW(), NOW())
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
