class Plan < ApplicationRecord
  SLUGGABLE = /\A[a-z0-9_-]+\z/

  FEATURE_REGISTRY = {
    "content_types" => {
      type:    "multi_select",
      options: %w[url video audio file],
      label:   "Tipos de contenido"
    },
    "availability_schedule" => {
      type:  "boolean",
      label: "Horario de disponibilidad"
    },
    "availability_quota" => {
      type:  "boolean",
      label: "Cupo de visitas"
    },
    "analytics" => {
      type:  "boolean",
      label: "Analíticas"
    },
    "members" => {
      type:  "boolean",
      label: "Miembros del equipo"
    },
    "dwell_time" => {
      type:  "boolean",
      label: "Permanencia"
    }
  }.freeze

  FULL_FEATURES_CONFIG = {
    "content_types"         => %w[url video audio file],
    "availability_schedule" => true,
    "availability_quota"    => true,
    "analytics"             => true,
    "members"               => true,
    "dwell_time"            => true
  }.freeze

  # Returns features_config falling back to full access when empty (e.g. legacy plans).
  def effective_features_config
    return FULL_FEATURES_CONFIG if features_config.blank?

    features_config
  end

  validates :name,               presence: true, length: { maximum: 100  }
  validates :slug,               presence: true, uniqueness: true, format: { with: SLUGGABLE }, length: { maximum: 100 }
  validates :public_description, length: { maximum: 1000 }, allow_nil: true
  validates :cta_text,           length: { maximum: 100  }, allow_nil: true
  validates :cta_url,            length: { maximum: 2048 }, allow_nil: true
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
  before_save :ensure_single_onboarding_plan

  scope :visible, -> { where(is_visible: true) }
  scope :sorted,  -> { order(sort_order: :asc, created_at: :asc) }
  scope :public_plans, -> { visible.sorted }

  private

  # When marking a plan as the onboarding plan, deactivate any other plan that
  # currently holds that flag. Uses update_all to skip callbacks and avoid recursion.
  def ensure_single_onboarding_plan
    return unless is_onboarding_plan && will_save_change_to_is_onboarding_plan?
    Plan.where.not(id: id).where(is_onboarding_plan: true).update_all(is_onboarding_plan: false)
  end

  # yearly_price_computed is derived — never set it manually.
  # Formula: (monthly_price * 12) * (1 - annual_discount_percent / 100)
  def compute_yearly_price
    return unless monthly_price

    annual_base = monthly_price * 12
    discount    = annual_base * annual_discount_percent / 100.0
    self.yearly_price_computed = (annual_base - discount).round(2)
  end
end
