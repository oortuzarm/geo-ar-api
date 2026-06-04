module Api
  module Public
    # Public Smart Links endpoints — no authentication required.
    # Smart Links are resolved by organization_slug + slug.
    class SmartLinksController < ApplicationController
      # GET /api/public/smart_links/:organization_slug/:slug
      def show
        smart_link = resolve_smart_link!

        unless smart_link.status == "active"
          return render json: { error: "Smart Link no disponible." }, status: :not_found
        end

        record_event("smart_link_opened", smart_link)
        render json: smart_link.as_public_json
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Smart Link no encontrado." }, status: :not_found
      end

      # POST /api/public/smart_links/:organization_slug/:slug/validate
      def validate
        smart_link = resolve_smart_link!

        unless smart_link.status == "active"
          return render json: {
            allowed:      false,
            reason:       "smart_link_inactive",
            message:      "Este Smart Link no está disponible.",
            smartLink:    smart_link.as_public_json,
            availability: {}
          }, status: :unprocessable_entity
        end

        unless valid_coordinates?
          return render json: { error: "latitude y longitude son obligatorios." },
                        status: :unprocessable_entity
        end

        session_id = params[:session_id].to_s.strip
        if session_id.blank?
          return render json: { error: "session_id es obligatorio." },
                        status: :unprocessable_entity
        end

        result = SmartLinkValidationService.new(
          smart_link:            smart_link,
          lat:                   params[:latitude].to_f,
          lng:                   params[:longitude].to_f,
          session_id:            session_id,
          accuracy:              params[:accuracy]&.to_f,
          dwell_elapsed_seconds: params[:dwell_elapsed_seconds]&.to_i
        ).call

        render json: {
          allowed:           result.allowed,
          destinationUrl:    result.destination_url,
          matchedGeoPointId: result.matched_geo_point_id,
          reason:            result.reason,
          message:           result.message,
          smartLink:         smart_link.as_public_json,
          availability:      result.availability.transform_keys { |k| k.to_s.camelize(:lower) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Smart Link no encontrado." }, status: :not_found
      end

      private

      def resolve_smart_link!
        org = Organization.find_by!(slug: params[:organization_slug])
        org.smart_links.find_by!(slug: params[:slug])
      end

      def valid_coordinates?
        numeric?(params[:latitude]) && numeric?(params[:longitude])
      end

      def numeric?(value)
        return false if value.nil?
        Float(value)
        true
      rescue ArgumentError, TypeError
        false
      end

      def record_event(event_type, smart_link)
        AnalyticsEvent.create!(
          geo_project_id:   smart_link.project_id,
          geo_point_id:     nil,
          event_type:       event_type,
          session_id:       params[:session_id].presence || SecureRandom.uuid,
          event_date:       Date.current,
          source:           "smart_link",
          context_metadata: {
            smart_link_id:     smart_link.id,
            smart_link_slug:   smart_link.slug,
            organization_id:   smart_link.organization_id,
            organization_slug: smart_link.organization.slug
          }
        )
      rescue => e
        Rails.logger.error "[SMART_LINK] #{event_type} event failed: #{e.class}: #{e.message}"
      end
    end
  end
end
