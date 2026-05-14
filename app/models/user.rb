class User < ApplicationRecord
  has_secure_password
  has_many :geo_projects,          dependent: :nullify
  has_many :password_reset_tokens, dependent: :destroy
  has_many :memberships,           dependent: :destroy
  has_many :organizations,         through:   :memberships
  has_many :sent_invitations,      class_name: "Invitation", foreign_key: :invited_by_id, dependent: :nullify

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
