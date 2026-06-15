module Api
  module V1
    class LocationBlueprint < Blueprinter::Base
      identifier :id

      field :name
      field :description
      field :instructions
      field :active
      field :order
      field :latitude
      field :longitude

      field :boundary do |location|
        case location.activation_mode
        when "radius"
          { type: "radius", radiusMeters: location.activation_radius }
        when "polygon"
          { type: "polygon", polygon: location.activation_polygon }
        else
          { type: location.activation_mode }
        end
      end

      field :schedule do |location|
        avail = location.availability || {}
        {
          enabled:   avail["schedule_enabled"] || false,
          days:      avail["days"] || [],
          startTime: avail["start_time"],
          endTime:   avail["end_time"]
        }
      end

      field :quota do |location|
        avail = location.availability || {}
        limit = avail["quota_limit"]
        used  = (avail["quota_used"] || 0).to_i
        {
          enabled:   avail["quota_enabled"] || false,
          limit:     limit,
          used:      used,
          remaining: limit ? [ limit.to_i - used, 0 ].max : nil
        }
      end

      field :dwell do |location|
        {
          enabled: location.requires_dwell_time || false,
          seconds: location.dwell_time_seconds  || 0
        }
      end

      field :destination do |location|
        resolve_destination(location)
      end

      # Populated only for URL-type locations; nil for video/audio/file.
      # Values: website | whatsapp | form | reservation | ecommerce | social | map | coupon | custom
      field :destinationCategory do |location|
        location.content_type == "url" ? location.destination_category.presence : nil
      end

      # Physical/functional nature of the place.
      # Values: gastronomy | retail | health | tourism | culture | education | services | events |
      #         entertainment | transport | accommodation | sport | real_estate | corporate | other
      field :pointCategory do |location|
        location.point_category.presence
      end

      field :createdAt do |location|
        location.created_at.iso8601(3)
      end

      # ── Private helpers ────────────────────────────────────────────────────

      class << self
        private

        # Maps internal content storage to a v1 destination object.
        # All content types are normalised to { type: "url", url: "..." } in v1.
        def resolve_destination(location)
          url = extract_url(location)
          return { type: "url", url: nil } if url.nil?

          { type: "url", url: url }
        end

        def extract_url(location)
          cd = location.content_data

          case location.content_type
          when "url"
            cd.is_a?(Hash) && cd["url"].present? ? cd["url"] : location.lookiar_url.presence
          when "video", "audio", "file"
            cd.is_a?(Hash) ? cd["file_url"].presence : nil
          else
            location.lookiar_url.presence
          end
        end
      end
    end
  end
end
