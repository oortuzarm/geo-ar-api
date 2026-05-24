module Api
  module Admin
    class SiteConfigsController < BaseController
      NUMERIC_KEYS = %w[register_trial_days].freeze

      # PATCH /api/admin/site_configs/:id  (id = key name)
      def update
        key   = params[:id]
        value = params[:value].to_s.strip

        unless SiteConfig::ALLOWED_KEYS.include?(key)
          render json: { error: "Clave de configuración no reconocida." }, status: :unprocessable_entity
          return
        end

        if NUMERIC_KEYS.include?(key)
          int_val = value.to_i
          unless int_val > 0
            render json: { error: "El valor debe ser un entero positivo mayor que 0." }, status: :unprocessable_entity
            return
          end
          value = int_val.to_s
        end

        config = SiteConfig.set(key, value)
        render json: { key: config.key, value: config.value }
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end
end
