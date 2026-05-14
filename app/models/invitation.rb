class Invitation < ApplicationRecord
  belongs_to :organization
  belongs_to :invited_by, class_name: "User"

  INVITABLE_ROLES = %w[editor viewer].freeze
  TOKEN_EXPIRY    = 7.days

  before_save { email&.downcase! }

  validates :email, presence: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
  validates :role,  inclusion: { in: INVITABLE_ROLES }
  validates :email, uniqueness: {
    scope:      :organization_id,
    conditions: -> { where(accepted_at: nil) },
    message:    "ya tiene una invitación pendiente en esta organización"
  }

  # Creates (or replaces) a pending invitation and returns [record, raw_token].
  def self.generate_for(organization:, email:, role:, invited_by:)
    where(organization: organization, email: email, accepted_at: nil).destroy_all

    raw_token = SecureRandom.urlsafe_base64(32)
    record = create!(
      organization: organization,
      email:        email,
      role:         role,
      invited_by:   invited_by,
      token_digest: digest(raw_token),
      expires_at:   TOKEN_EXPIRY.from_now
    )
    [ record, raw_token ]
  end

  # Finds an invitation by its raw token regardless of state (expired/accepted).
  def self.find_by_token(raw_token)
    find_by(token_digest: digest(raw_token.to_s))
  end

  # Regenerates the token and extends expiry. Returns the new raw token.
  def refresh_token!
    raw_token = SecureRandom.urlsafe_base64(32)
    update!(token_digest: self.class.send(:digest, raw_token), expires_at: TOKEN_EXPIRY.from_now)
    raw_token
  end

  def accept!
    update!(accepted_at: Time.current)
  end

  def expired?
    expires_at <= Time.current
  end

  def accepted?
    accepted_at.present?
  end

  def pending?
    !accepted? && !expired?
  end

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token)
  end
  private_class_method :digest
end
