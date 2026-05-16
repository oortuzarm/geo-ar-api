class Plan < ApplicationRecord
  SLUGGABLE = /\A[a-z0-9_-]+\z/

  validates :name,  presence: true
  validates :slug,  presence: true, uniqueness: true, format: { with: SLUGGABLE }
  validates :monthly_price,
    presence: true,
    numericality: { greater_than_or_equal_to: 0 }
  validates :annual_discount_percent,
    numericality: { only_integer: true, in: 0..100 }
  validates :sort_order,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :trial_days,
    numericality: { only_integer: true, greater_than: 0 },
    allow_nil: true
  validates :location_limit,
    numericality: { only_integer: true, greater_than: 0 },
    allow_nil: true

  before_save :compute_yearly_price

  scope :visible, -> { where(is_visible: true) }
  scope :sorted,  -> { order(sort_order: :asc, created_at: :asc) }
  scope :public_plans, -> { visible.sorted }

  private

  # yearly_price_computed is derived — never set it manually.
  # Formula: (monthly_price * 12) * (1 - annual_discount_percent / 100)
  def compute_yearly_price
    return unless monthly_price

    annual_base = monthly_price * 12
    discount    = annual_base * annual_discount_percent / 100.0
    self.yearly_price_computed = (annual_base - discount).round(2)
  end
end
