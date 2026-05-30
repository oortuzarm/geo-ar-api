class User < ApplicationRecord
  has_secure_password
  belongs_to :plan,                 optional: true
  belongs_to :onboarding_category, optional: true, class_name: "OnboardingCategory", foreign_key: :onboarding_category_id
  belongs_to :onboarding_industry, optional: true, class_name: "OnboardingOption",   foreign_key: :onboarding_industry_id
  belongs_to :onboarding_org_type, optional: true, class_name: "OnboardingOption",   foreign_key: :onboarding_org_type_id
  belongs_to :onboarding_org_size, optional: true, class_name: "OnboardingOption",   foreign_key: :onboarding_org_size_id
  belongs_to :onboarding_objective, optional: true, class_name: "OnboardingOption",  foreign_key: :onboarding_objective_id

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

  validates :first_name, length: { maximum: 100 }, allow_nil: true
  validates :last_name,  length: { maximum: 100 }, allow_nil: true
  validates :company,    length: { maximum: 150 }, allow_nil: true
  validates :job_title,  length: { maximum: 150 }, allow_nil: true
  validates :country,    length: { maximum: 100 }, allow_nil: true
  validates :time_zone,  length: { maximum: 100 }, allow_nil: true

  # ── Subscription helpers ────────────────────────────────────────────────────

  # The resolved location cap for this user. Priority:
  #   1. custom_location_limit (set by admin for one-off deals / enterprise)
  #   2. plan.location_limit
  #   3. plan_id nil → 0  (no plan chosen yet — block creation until plan is selected)
  def effective_location_limit
    return custom_location_limit if custom_location_limit.present?
    return plan.location_limit   if plan.present?
    0
  end

  # Current total geo_points owned by this user across all projects.
  def current_location_count
    GeoPoint.joins(:geo_project)
            .where(geo_projects: { user_id: id })
            .count
  end

  # A trial is active when ALL of the following hold:
  #   - subscription_status == "trial"
  #   - plan_id is present (a plan was selected to start the trial)
  #   - trial_ends_at is set (nil is NOT treated as open-ended)
  #   - the end-of-day deadline has not yet passed
  def trial_active?
    return false unless subscription_status == "trial"
    return false if plan_id.nil?
    return false if trial_ends_at.nil?

    deadline = trial_ends_at.in_time_zone.end_of_day
    now      = Time.zone.now
    Rails.logger.info "[TRIAL_CHECK] user_id=#{id} now=#{now.iso8601} " \
                      "trial_ends_at=#{trial_ends_at.iso8601} deadline=#{deadline.iso8601} active=#{deadline >= now}"
    deadline >= now
  end

  # Expired when an explicit end date was set AND the full day has passed.
  # Requires plan_id; no plan → not expired, just inactive (plan not chosen yet).
  def trial_expired?
    return false unless subscription_status == "trial"
    return false if plan_id.nil?
    return false if trial_ends_at.nil?

    deadline = trial_ends_at.in_time_zone.end_of_day
    now      = Time.zone.now
    Rails.logger.info "[TRIAL_CHECK] user_id=#{id} now=#{now.iso8601} " \
                      "trial_ends_at=#{trial_ends_at.iso8601} deadline=#{deadline.iso8601} expired=#{deadline < now}"
    deadline < now
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
