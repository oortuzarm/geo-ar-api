class OnboardingOption < ApplicationRecord
  GROUPS = %w[industry org_type org_size objective].freeze

  validates :name,         presence: true
  validates :slug,         presence: true, uniqueness: { scope: :option_group }, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :option_group, presence: true, inclusion: { in: GROUPS }
  validates :position,     numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:position, :name) }
  scope :for_group,    ->(g) { where(option_group: g) }
  scope :grouped_by,   -> { order(:option_group) }
end
