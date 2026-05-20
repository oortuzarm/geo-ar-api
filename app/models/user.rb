class User < ApplicationRecord
  has_secure_password
  belongs_to :plan, optional: true

  has_many :geo_projects,          dependent: :destroy
  has_many :password_reset_tokens, dependent: :destroy
  has_many :memberships,           dependent: :destroy
  has_many :organizations,         through:   :memberships
  # invited_by_id is NOT NULL in the DB — must destroy, not nullify.
  has_many :sent_invitations,      class_name: "Invitation", foreign_key: :invited_by_id, dependent: :destroy

  before_destroy :purge_sole_owned_organizations

  ROLES                 = %w[user admin].freeze
  STATUSES              = %w[active suspended].freeze
  SUBSCRIPTION_STATUSES = %w[trial active expired canceled].freeze

  before_save { email&.downcase! }

  validates :email,
    presence:   true,
    uniqueness: { case_insensitive: true },
    format:     { with: /\A[^@\s]+@[^@\s]+\z/ }
  validates :role,                inclusion: { in: ROLES }
  validates :status,              inclusion: { in: STATUSES }
  validates :subscription_status, inclusion: { in: SUBSCRIPTION_STATUSES }
  validates :custom_location_limit,
    numericality: { only_integer: true, greater_than: 0 },
    allow_nil:    true

  # ── Subscription helpers ────────────────────────────────────────────────────

  # The resolved location cap for this user. Priority:
  #   1. custom_location_limit (set by admin for one-off deals / enterprise)
  #   2. plan.location_limit
  #   3. nil → unlimited
  def effective_location_limit
    return custom_location_limit if custom_location_limit.present?
    plan&.location_limit
  end

  # Current total geo_points owned by this user across all projects.
  def current_location_count
    GeoPoint.joins(:geo_project)
            .where(geo_projects: { user_id: id })
            .count
  end

  def trial_active?
    subscription_status == "trial" &&
      trial_ends_at.present? &&
      Time.current <= trial_ends_at
  end

  def trial_expired?
    subscription_status == "trial" &&
      trial_ends_at.present? &&
      Time.current > trial_ends_at
  end

  # True when the user may take billable actions (create content, etc.).
  def subscription_active?
    return true if subscription_status == "active"
    trial_active?
  end

  def can_create_location?
    return false unless subscription_active?

    limit = effective_location_limit
    return true if limit.nil? # unlimited plan

    current_location_count < limit
  end

  private

  # Destroy organizations where this user is the sole member before the user
  # is deleted. Without this, the org would become an empty orphan (no members).
  # Cascades via Organization.has_many :memberships/:invitations, dependent: :destroy.
  def purge_sole_owned_organizations
    organizations.each do |org|
      org.destroy! if org.memberships.count == 1
    end
  end
end
