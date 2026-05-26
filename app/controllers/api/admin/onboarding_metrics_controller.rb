module Api
  module Admin
    class OnboardingMetricsController < BaseController
      # GET /api/admin/onboarding/metrics
      def index
        total_users     = User.count
        completed_count = User.where(onboarding_completed: true).count
        completion_rate = total_users > 0 ? (completed_count.to_f / total_users * 100).round(1) : 0.0

        render json: {
          totals: {
            users:          total_users,
            completed:      completed_count,
            completionRate: completion_rate
          },
          categories:        distribution_for(:onboarding_category_id, OnboardingCategory),
          industries:        distribution_for(:onboarding_industry_id,  OnboardingOption),
          organizationTypes: distribution_for(:onboarding_org_type_id,  OnboardingOption),
          organizationSizes: distribution_for(:onboarding_org_size_id,  OnboardingOption),
          objectives:        distribution_for(:onboarding_objective_id, OnboardingOption),
          countries:         country_distribution
        }
      end

      private

      # Groups users by +user_col+, resolves names from +klass+, returns sorted array.
      # Two queries: one GROUP BY on users, one WHERE id IN on the lookup table.
      def country_distribution
        User
          .where("country IS NOT NULL AND TRIM(country) != ''")
          .group(:country)
          .order("count_all DESC, country ASC")
          .limit(10)
          .count
          .map { |name, count| { name: name, count: count } }
      end

      def distribution_for(user_col, klass)
        counts = User.where.not(user_col => nil)
                     .group(user_col)
                     .count
        return [] if counts.empty?

        names = klass.where(id: counts.keys).pluck(:id, :name).to_h
        counts
          .map { |id, count| { id: id, name: names[id], count: count } }
          .sort_by { |h| -h[:count] }
      end
    end
  end
end
