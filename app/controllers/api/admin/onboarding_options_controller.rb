module Api
  module Admin
    class OnboardingOptionsController < BaseController
      # GET /api/admin/onboarding_options?group=industry
      def index
        scope = OnboardingOption.ordered
        scope = scope.for_group(params[:group]) if params[:group].present?
        render json: scope.map { |o| serialize(o) }
      end

      # POST /api/admin/onboarding_options
      def create
        option = OnboardingOption.new(option_params)
        if option.save
          render json: serialize(option), status: :created
        else
          render json: { error: option.errors.full_messages.first }, status: :unprocessable_entity
        end
      end

      # PATCH /api/admin/onboarding_options/:id
      def update
        option = OnboardingOption.find(params[:id])
        if option.update(option_params)
          render json: serialize(option)
        else
          render json: { error: option.errors.full_messages.first }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Opción no encontrada." }, status: :not_found
      end

      # DELETE /api/admin/onboarding_options/:id
      def destroy
        option = OnboardingOption.find(params[:id])
        option.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Opción no encontrada." }, status: :not_found
      end

      # PATCH /api/admin/onboarding_options/reorder
      # Body: { ids: [5, 3, 1, 7, 2] }  — ordered array of option IDs for the group.
      # Sets position 1, 2, 3, … for the provided IDs in the given order.
      def reorder
        ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
        return render json: { error: "ids is required" }, status: :bad_request if ids.empty?

        ActiveRecord::Base.transaction do
          ids.each_with_index do |id, index|
            OnboardingOption.where(id: id).update_all(position: index + 1)
          end
        end

        head :ok
      rescue => e
        Rails.logger.error("[ONBOARDING_REORDER] #{e.class}: #{e.message}")
        render json: { error: "Failed to reorder" }, status: :internal_server_error
      end

      private

      def option_params
        # Frontend sends `group`; DB column is `option_group` (reserved word avoidance).
        # Map the incoming param name to the correct attribute name.
        permitted = params.permit(:name, :slug, :position, :active)
        permitted[:option_group] = params[:group] if params[:group].present?
        permitted
      end

      # JSON always emits `group` so the frontend API contract stays unchanged.
      def serialize(o)
        {
          id:         o.id,
          group:      o.option_group,
          name:       o.name,
          slug:       o.slug,
          position:   o.position,
          active:     o.active,
          usageCount: o.usage_count,
          createdAt:  o.created_at.iso8601(3),
          updatedAt:  o.updated_at.iso8601(3)
        }
      end
    end
  end
end
