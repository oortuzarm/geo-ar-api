class User < ApplicationRecord
  has_secure_password
  has_many :geo_projects,          dependent: :nullify
  has_many :password_reset_tokens, dependent: :destroy

  ROLES    = %w[user admin].freeze
  STATUSES = %w[active suspended].freeze

  before_save { email&.downcase! }

  validates :email,
    presence:   true,
    uniqueness: { case_insensitive: true },
    format:     { with: /\A[^@\s]+@[^@\s]+\z/ }
  validates :role,   inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
end
