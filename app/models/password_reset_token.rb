class PasswordResetToken < ApplicationRecord
  belongs_to :user

  TOKEN_EXPIRY = 60.minutes

  # Generates a raw token, persists only its digest, returns the raw token.
  # Invalidates any previous unexpired tokens for the same user.
  def self.generate_for(user)
    where(user: user).where(used_at: nil).where("expires_at > ?", Time.current)
                     .update_all(expires_at: Time.current)

    raw_token = SecureRandom.urlsafe_base64(32)
    create!(
      user:         user,
      token_digest: digest(raw_token),
      expires_at:   TOKEN_EXPIRY.from_now
    )
    raw_token
  end

  # Returns the record if the raw token is valid (exists, unused, not expired).
  def self.find_valid(raw_token)
    record = find_by(token_digest: digest(raw_token))
    return nil if record.nil?
    return nil if record.used_at.present?
    return nil if record.expires_at <= Time.current
    record
  end

  # Marks this token as used and invalidates all other active tokens for the user.
  def use!
    update!(used_at: Time.current)
    self.class.where(user: user, used_at: nil)
              .where("expires_at > ?", Time.current)
              .where.not(id: id)
              .update_all(expires_at: Time.current)
  end

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token)
  end
  private_class_method :digest
end
