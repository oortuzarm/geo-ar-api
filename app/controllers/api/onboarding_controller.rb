module Api
  class OnboardingController < ApplicationController
    before_action :authenticate_user!

    # GET /api/onboarding/config
    # Returns all active categories + all active options grouped by type.
    # Used by the frontend to build the onboarding UI without hardcoded data.
    def config
      categories = OnboardingCategory.active.ordered.map do |c|
        { id: c.id, name: c.name, slug: c.slug, description: c.description, iconName: c.icon_name }
      end

      options_by_group = OnboardingOption::GROUPS.each_with_object({}) do |group, hash|
        hash[group] = OnboardingOption.active.for_group(group).ordered.map do |o|
          { id: o.id, name: o.name, slug: o.slug }
        end
      end

      render json: {
        categories: categories,
        options:    options_by_group
      }
    rescue => e
      Rails.logger.error "[ONBOARDING_CONFIG] #{e.class}: #{e.message}"
      render json: { error: "Error al cargar la configuración de onboarding." }, status: :internal_server_error
    end

    # POST /api/onboarding
    # Saves onboarding state for the current user.
    # Accepts partial submissions (skippable steps).
    def submit
      cols = User.column_names
      attrs = {}

      # Step 1 — workspace title is saved on the geo_project, not the user.
      # Company is a user profile field.
      if cols.include?("company") && params[:company].present?
        attrs[:company] = params[:company].to_s.strip
      end

      # Step 2 — category selection
      if params[:category_id].present?
        category = OnboardingCategory.find_by(id: params[:category_id])
        if category
          attrs[:onboarding_category_id] = category.id
          category.increment!(:usage_count)
        end
      end

      # Step 3 — options
      %w[industry org_type org_size objective].each do |group|
        key    = "#{group}_id"
        col    = "onboarding_#{group}_id"
        next unless cols.include?(col) && params[key].present?

        option = OnboardingOption.active.for_group(group).find_by(id: params[key])
        if option
          attrs[col.to_sym] = option.id
          option.increment!(:usage_count)
        end
      end

      # Country (already a string column from profile fields migration)
      if cols.include?("country") && params[:country].present?
        attrs[:country] = params[:country].to_s.strip
      end

      # Mark completed only when explicitly passed
      if cols.include?("onboarding_completed") && params[:completed] == true
        attrs[:onboarding_completed] = true
      end

      # Step 1 — update workspace title on the most-recent project
      if params[:workspace_title].present?
        project = current_user.geo_projects.order(created_at: :asc).first
        if project
          project.update(title: params[:workspace_title].to_s.strip)
        end
      end

      current_user.update!(attrs) unless attrs.empty?

      render json: {
        onboardingCompleted: current_user.try(:onboarding_completed) || false,
        categoryId:          current_user.try(:onboarding_category_id),
        industryId:          current_user.try(:onboarding_industry_id),
        orgTypeId:           current_user.try(:onboarding_org_type_id),
        orgSizeId:           current_user.try(:onboarding_org_size_id),
        objectiveId:         current_user.try(:onboarding_objective_id),
        country:             current_user.try(:country)
      }

    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first || e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "[ONBOARDING_SUBMIT] #{e.class}: #{e.message}"
      render json: { error: "Error al guardar el onboarding." }, status: :internal_server_error
    end
  end
end
