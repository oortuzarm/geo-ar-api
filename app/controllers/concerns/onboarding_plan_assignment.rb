module OnboardingPlanAssignment
  extend ActiveSupport::Concern

  private

  # Returns a hash of plan/trial attributes to merge into User.create! when a
  # valid onboarding plan is configured. Returns {} (no-op) otherwise so the
  # user is created safely with DB defaults (plan_id nil, effective_location_limit 0).
  def resolve_onboarding_plan_attrs(plan = nil)
    plan ||= Plan.find_by(is_onboarding_plan: true)

    unless plan
      Rails.logger.warn "[ONBOARDING_PLAN] No onboarding plan configured — user created without plan assignment"
      return {}
    end

    unless plan.has_trial && plan.trial_days.to_i > 0
      Rails.logger.warn "[ONBOARDING_PLAN] Plan '#{plan.slug}' has no valid trial " \
                        "(has_trial=#{plan.has_trial} trial_days=#{plan.trial_days.inspect}) " \
                        "— user created without plan assignment"
      return {}
    end

    now = Time.zone.now
    Rails.logger.info "[ONBOARDING_PLAN] Assigning plan=#{plan.slug} " \
                      "trial_days=#{plan.trial_days} ends_at=#{(now + plan.trial_days.days).iso8601}"
    {
      plan_id:             plan.id,
      subscription_status: "trial",
      trial_starts_at:     now,
      trial_ends_at:       now + plan.trial_days.days
    }
  end
end
