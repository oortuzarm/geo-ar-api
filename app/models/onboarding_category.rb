class OnboardingCategory < ApplicationRecord
  has_many :users, foreign_key: :onboarding_category_id, dependent: :nullify

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active,   -> { where(active: true) }
  scope :ordered,  -> { order(:position, :name) }
end
