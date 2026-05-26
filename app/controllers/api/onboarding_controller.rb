module Api
  class OnboardingController < ApplicationController
    before_action :authenticate_user!

    # GET /api/onboarding/config
    def config
      categories = OnboardingCategory
        .active
        .order(:position)
        .map do |category|
          {
            id:       category.id,
            name:     category.name,
            slug:     category.slug,
            iconName: category.icon_name,
            position: category.position
          }
        end

      options = OnboardingOption
        .active
        .order(:option_group, :position)
        .map do |option|
          {
            id:       option.id,
            group:    option.option_group,
            name:     option.name,
            slug:     option.slug,
            position: option.position
          }
        end

      render json: { categories: categories, options: options }, status: :ok
    rescue => e
      Rails.logger.error("[ONBOARDING_CONFIG] #{e.class}: #{e.message}")
      render json: { categories: [], options: [] }, status: :ok
    end

    # POST /api/onboarding
    # normalize_params converts all camelCase request keys to snake_case before this runs.
    def submit
      attrs = {}

      attrs[:company] = params[:company].to_s.strip if params[:company].present?

      if params[:category_id].present?
        cat = OnboardingCategory.find_by(id: params[:category_id])
        if cat
          attrs[:onboarding_category_id] = cat.id
          cat.increment!(:usage_count)
        end
      end

      # Map each option group param to its exact users column.
      {
        industry:  :onboarding_industry_id,
        org_type:  :onboarding_org_type_id,
        org_size:  :onboarding_org_size_id,
        objective: :onboarding_objective_id
      }.each do |group, col|
        param_key = :"#{group}_id"
        next unless params[param_key].present?

        option = OnboardingOption
          .where(option_group: group.to_s, active: true)
          .find_by(id: params[param_key])
        next unless option

        attrs[col] = option.id
        option.increment!(:usage_count)
      end

      attrs[:country] = params[:country].to_s.strip if params[:country].present?

      # params[:completed] is a JSON boolean — truthy only when explicitly true.
      attrs[:onboarding_completed] = true if params[:completed]

      if params[:workspace_title].present?
        project = current_user.geo_projects.order(created_at: :asc).first
        project&.update(title: params[:workspace_title].to_s.strip)
      end

      current_user.update!(attrs) unless attrs.empty?

      render json: {
        onboardingCompleted: current_user.onboarding_completed,
        categoryId:          current_user.onboarding_category_id,
        industryId:          current_user.onboarding_industry_id,
        orgTypeId:           current_user.onboarding_org_type_id,
        orgSizeId:           current_user.onboarding_org_size_id,
        objectiveId:         current_user.onboarding_objective_id,
        country:             current_user.country
      }, status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first || e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("[ONBOARDING_SUBMIT] #{e.class}: #{e.message}")
      render json: { error: "Failed to save onboarding" }, status: :unprocessable_entity
    end
  end
end
