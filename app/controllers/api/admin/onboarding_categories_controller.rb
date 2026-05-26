module Api
  module Admin
    class OnboardingCategoriesController < BaseController
      # GET /api/admin/onboarding_categories
      def index
        categories = OnboardingCategory.ordered
        render json: categories.map { |c| serialize(c) }
      end

      # POST /api/admin/onboarding_categories
      def create
        category = OnboardingCategory.new(category_params)
        if category.save
          render json: serialize(category), status: :created
        else
          render json: { error: category.errors.full_messages.first }, status: :unprocessable_entity
        end
      end

      # PATCH /api/admin/onboarding_categories/:id
      def update
        category = OnboardingCategory.find(params[:id])
        if category.update(category_params)
          render json: serialize(category)
        else
          render json: { error: category.errors.full_messages.first }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Categoría no encontrada." }, status: :not_found
      end

      # DELETE /api/admin/onboarding_categories/:id
      def destroy
        category = OnboardingCategory.find(params[:id])
        category.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Categoría no encontrada." }, status: :not_found
      end

      private

      def category_params
        params.permit(:name, :slug, :description, :icon_name, :position, :active)
      end

      def serialize(c)
        {
          id:          c.id,
          name:        c.name,
          slug:        c.slug,
          description: c.description,
          iconName:    c.icon_name,
          position:    c.position,
          active:      c.active,
          usageCount:  c.usage_count,
          createdAt:   c.created_at.iso8601(3),
          updatedAt:   c.updated_at.iso8601(3),
        }
      end
    end
  end
end
