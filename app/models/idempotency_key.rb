class IdempotencyKey < ApplicationRecord
  TTL         = 24.hours
  IN_FLIGHT   = 30.seconds

  belongs_to :api_credential

  validates :idempotency_key, presence: true, length: { maximum: 255 }
  validates :endpoint,        presence: true
  validates :expires_at,      presence: true

  scope :active, -> { where("expires_at > ?", Time.current) }

  def complete?
    response_body.present?
  end

  def in_flight?
    !complete? && locked_at.present? && locked_at > IN_FLIGHT.ago
  end
end
