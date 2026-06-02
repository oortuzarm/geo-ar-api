class ApiCredential < ApplicationRecord
  STATUSES = %w[active revoked suspended expired deleted].freeze

  VALID_SCOPES = %w[
    projects:read
    locations:read
    presence:validate
    presence:check
    events:read
    analytics:read
    live_visits:read
    webhooks:read
    webhooks:write
    credentials:read
    credentials:write
  ].freeze

  KEY_PUBLIC_PREFIX = "ubk_live_"
  KEY_SECRET_PREFIX = "ubs_live_"

  belongs_to :organization
  belongs_to :created_by_user, class_name: "User", foreign_key: :created_by_user_id, optional: true
  belongs_to :revoked_by_user, class_name: "User", foreign_key: :revoked_by_user_id, optional: true

  validates :name,             presence: true, length: { maximum: 255 }
  validates :key_public,       presence: true, uniqueness: true
  validates :key_secret_digest, presence: true
  validates :status,           inclusion: { in: STATUSES }
  validate  :scopes_are_valid

  # Generates a new unsaved ApiCredential and returns [credential, plaintext_secret].
  # The plaintext secret is shown only once and never stored.
  def self.build_with_secret(attributes = {})
    key_public = "#{KEY_PUBLIC_PREFIX}#{SecureRandom.alphanumeric(32)}"
    key_secret = "#{KEY_SECRET_PREFIX}#{SecureRandom.alphanumeric(48)}"

    credential = new(attributes.merge(
      key_public:        key_public,
      key_secret_digest: digest(key_secret)
    ))

    [ credential, key_secret ]
  end

  def self.digest(secret)
    Digest::SHA256.hexdigest(secret)
  end

  # Validates a provided plaintext secret against stored digest(s).
  # Supports the previous secret during a rotation grace window.
  def authenticate(provided_secret)
    return false if provided_secret.blank?

    incoming_digest = self.class.digest(provided_secret)

    current_match  = ActiveSupport::SecurityUtils.secure_compare(key_secret_digest, incoming_digest)
    previous_match = previous_key_valid? &&
                     ActiveSupport::SecurityUtils.secure_compare(previous_key_secret_digest, incoming_digest)

    current_match || previous_match
  end

  def active?
    status == "active" && !expired?
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  private

  def previous_key_valid?
    previous_key_secret_digest.present? &&
      previous_key_expires_at.present? &&
      previous_key_expires_at > Time.current
  end

  def scopes_are_valid
    return if scopes.blank?

    invalid = scopes - VALID_SCOPES
    errors.add(:scopes, "contains invalid scopes: #{invalid.join(', ')}") if invalid.any?
  end
end
