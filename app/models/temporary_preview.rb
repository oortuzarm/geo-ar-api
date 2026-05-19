class TemporaryPreview < ApplicationRecord
  EXPIRES_IN      = 30.minutes
  MAX_POINTS      = 10
  MAX_PAYLOAD_BYTES = 100.kilobytes

  validates :token,      presence: true, uniqueness: true
  validates :payload,    presence: true
  validates :expires_at, presence: true

  before_validation :assign_token,      on: :create
  before_validation :assign_expires_at, on: :create

  scope :active,  -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }

  def expired?
    expires_at <= Time.current
  end

  private

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def assign_expires_at
    self.expires_at ||= EXPIRES_IN.from_now
  end
end
