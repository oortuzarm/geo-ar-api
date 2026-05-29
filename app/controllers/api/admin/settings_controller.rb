module Api
  module Admin
    class SettingsController < BaseController
      COMMUNITY_DEFAULTS = {
        "community_map_disabled_title"       => "Mapa comunitario próximamente",
        "community_map_disabled_description" =>
          "Estamos preparando esta función para que puedas descubrir experiencias compartidas por categoría."
      }.freeze

      def index
        render json: serialized
      end

      def update
        errors = {}

        if params.key?(:community_map_enabled)
          raw = params[:community_map_enabled].to_s.downcase.strip
          if %w[true false].include?(raw)
            SiteConfig.set("community_map_enabled", raw)
          else
            errors[:communityMapEnabled] = "Debe ser true o false."
          end
        end

        if params.key?(:show_community_map_section)
          raw = params[:show_community_map_section].to_s.downcase.strip
          if %w[true false].include?(raw)
            SiteConfig.set("show_community_map_section", raw)
          else
            errors[:showCommunityMapSection] = "Debe ser true o false."
          end
        end

        %w[community_map_disabled_title community_map_disabled_description].each do |key|
          next unless params.key?(key.to_sym)
          val = params[key.to_sym].to_s.strip
          if val.blank?
            errors[key.camelize(:lower)] = "No puede quedar vacío."
          else
            SiteConfig.set(key, val)
          end
        end

        if errors.any?
          render json: { errors: errors }, status: :unprocessable_entity
        else
          render json: serialized
        end
      end

      private

      def serialized
        {
          communityMapEnabled:
            SiteConfig.enabled?("community_map_enabled"),
          communityMapDisabledTitle:
            SiteConfig.get("community_map_disabled_title",       default: COMMUNITY_DEFAULTS["community_map_disabled_title"]),
          communityMapDisabledDescription:
            SiteConfig.get("community_map_disabled_description", default: COMMUNITY_DEFAULTS["community_map_disabled_description"]),
          showCommunityMapSection:
            SiteConfig.get("show_community_map_section", default: "true") == "true"
        }
      end
    end
  end
end
