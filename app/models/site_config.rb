class SiteConfig < ApplicationRecord
  ALLOWED_KEYS = %w[
    register_trial_days
    community_map_enabled
    community_map_disabled_title
    community_map_disabled_description
  ].freeze

  validates :key,   presence: true, uniqueness: true, inclusion: { in: ALLOWED_KEYS }
  validates :value, presence: true

  def self.get(key, default: nil)
    find_by(key: key)&.value || default
  end

  def self.set(key, value)
    record = find_or_initialize_by(key: key)
    record.value = value.to_s
    record.save!
    record
  end

  # Interprets "true"/"false" string values as booleans.
  def self.enabled?(key)
    get(key, default: "false") == "true"
  end
end
