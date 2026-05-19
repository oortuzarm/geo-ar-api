class TemporaryPreview < ApplicationRecord
  EXPIRES_IN      = 30.minutes
  MAX_POINTS      = 10
  MAX_PAYLOAD_BYTES = 100.kilobytes

  validates :token,      presence: true, uniqueness: true
  validates :payload,    exclusion: { in: [nil], message: "can't be nil" }
  validates :expires_at, presence: true

  before_validation :assign_token,      on: :create
  before_validation :assign_expires_at, on: :create

  scope :active,   -> { where(claimed_at: nil).where("expires_at > ?", Time.current) }
  scope :expired,  -> { where("expires_at <= ?", Time.current) }
  scope :claimed,  -> { where.not(claimed_at: nil) }

  def expired?
    expires_at <= Time.current
  end

  def claimed?
    claimed_at.present?
  end

  private

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def assign_expires_at
    self.expires_at ||= EXPIRES_IN.from_now
  end
end
