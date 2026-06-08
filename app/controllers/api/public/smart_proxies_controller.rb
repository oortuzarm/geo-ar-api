module Api
  module Public
    # Reverse proxy endpoint — serves the destination site's HTML with URL
    # rewriting and the Ubyca analytics script injected.
    #
    # Route:  GET /proxy/:org_slug/:proxy_slug(/*path)
    # Note: this route lives at the root level (outside /api/public/) so the
    # public URL is https://go.ubyca.com/proxy/:org_slug/:proxy_slug/...
    class SmartProxiesController < ApplicationController
      # GET /proxy/:org_slug/:proxy_slug(/*path)
      def show
        # DIAG: log every inbound request so we can confirm which assets reach Rails.
        Rails.logger.info "[SP_CTRL] method=#{request.method} " \
                          "request_path=#{request.path.inspect} " \
                          "org=#{params[:org_slug].inspect} " \
                          "proxy=#{params[:proxy_slug].inspect} " \
                          "path_param=#{params[:path].inspect} " \
                          "format=#{params[:format].inspect}"

        smart_proxy = SmartProxy.resolve(
          host:       request.host,
          org_slug:   params[:org_slug],
          proxy_slug: params[:proxy_slug]
        )

        return render_not_found unless smart_proxy

        # Rails strips the file extension from *path and stores it in params[:format].
        # Reconstruct the full path before passing it to the fetcher.
        path = params[:path].to_s
        path = "#{path}.#{params[:format]}" if params[:format].present?

        Rails.logger.info "[SP_CTRL] reconstructed_path=#{path.inspect}"

        fetcher = SmartProxyFetcher.new(smart_proxy, path, request.base_url)
        result  = fetcher.call

        # DIAG: log what we are sending back to the browser.
        Rails.logger.info "[SP_CTRL] response content_type=#{result.content_type.inspect} " \
                          "success=#{result.success} " \
                          "body_bytes=#{result.body.to_s.bytesize} " \
                          "error=#{result.error.inspect}"

        if result.success
          mark_supported(smart_proxy)
          record_server_event("smart_proxy_fetch_success", smart_proxy, path) if path.blank?

          response.headers["Cache-Control"] = "no-store"
          response.headers["X-Robots-Tag"]  = "noindex, nofollow"
          render body: result.body, content_type: result.content_type
        else
          mark_failed(smart_proxy)
          record_server_event("smart_proxy_fetch_failed", smart_proxy, path) if path.blank?

          render body: error_html(smart_proxy, result.error),
                 content_type: "text/html; charset=utf-8",
                 status: :bad_gateway
        end
      end

      private

      def render_not_found
        render json: { error: "Smart Proxy no encontrado." }, status: :not_found
      end

      def mark_supported(smart_proxy)
        return if smart_proxy.proxy_status == "supported"
        smart_proxy.update_column(:proxy_status, "supported")
      rescue => e
        Rails.logger.warn "[SMART_PROXY] status update failed: #{e.message}"
      end

      def mark_failed(smart_proxy)
        return if smart_proxy.proxy_status == "failed"
        smart_proxy.update_column(:proxy_status, "failed")
      rescue => e
        Rails.logger.warn "[SMART_PROXY] status update failed: #{e.message}"
      end

      def record_server_event(event_type, smart_proxy, _path)
        AnalyticsEvent.create!(
          smart_proxy_id:   smart_proxy.id,
          geo_project_id:   nil,
          event_type:       event_type,
          session_id:       SecureRandom.uuid,
          event_date:       Date.current,
          source:           "smart_proxy",
          context_metadata: {
            smart_proxy_id:   smart_proxy.id,
            smart_proxy_slug: smart_proxy.slug,
            organization_id:  smart_proxy.organization_id,
            org_slug:         smart_proxy.organization.slug
          }
        )
      rescue => e
        Rails.logger.error "[SMART_PROXY] server event recording failed: #{e.message}"
      end

      def error_html(smart_proxy, error_code)
        <<~HTML
          <!DOCTYPE html>
          <html lang="es">
          <head><meta charset="utf-8"><title>Contenido no disponible</title>
          <style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f5f5f5}
          .box{background:#fff;padding:2rem 3rem;border-radius:8px;text-align:center;max-width:480px}</style>
          </head>
          <body><div class="box">
          <p style="font-size:2rem">⚠️</p>
          <h1 style="font-size:1.25rem;margin-bottom:0.5rem">Contenido no disponible</h1>
          <p style="color:#666;font-size:0.9rem">No se pudo cargar el sitio. Intenta de nuevo más tarde.</p>
          <p style="color:#aaa;font-size:0.75rem;margin-top:1.5rem">#{smart_proxy.name} · error: #{error_code}</p>
          </div></body></html>
        HTML
      end
    end
  end
end
