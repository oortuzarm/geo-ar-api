module Api
  module Public
    class SettingsController < ApplicationController
      def index
        render json: {
          communityMapEnabled:
            SiteConfig.enabled?("community_map_enabled"),
          communityMapDisabledTitle:
            SiteConfig.get("community_map_disabled_title",
              default: "Mapa comunitario próximamente"),
          communityMapDisabledDescription:
            SiteConfig.get("community_map_disabled_description",
              default: "Estamos preparando esta función para que puedas descubrir experiencias compartidas por categoría.")
        }
      end
    end
  end
end
