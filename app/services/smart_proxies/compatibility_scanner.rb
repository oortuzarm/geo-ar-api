require "net/http"
require "openssl"

module SmartProxies
  class CompatibilityScanner
    MAX_REDIRECTS   = 5
    CONNECT_TIMEOUT = 10
    READ_TIMEOUT    = 15
    MAX_BODY_BYTES  = 524_288  # 512 KB — enough to detect all signals

    BOT_BODY_SIGNALS = [
      "attention required",
      "just a moment",
      "un paso más",
      "captcha",
      "security check"
    ].freeze

    # Accepts either an existing SmartProxy record or a plain URL string.
    # When initialized with a URL string, `call` must not be used (no DB to write to);
    # use `run` instead to get the result hash directly.
    def initialize(smart_proxy_or_url)
      if smart_proxy_or_url.is_a?(String)
        @proxy = nil
        @url   = smart_proxy_or_url
      else
        @proxy = smart_proxy_or_url
        @url   = smart_proxy_or_url.destination_url
      end
    end

    # Runs the scan AND persists results to the SmartProxy record.
    # Requires that the scanner was initialized with a SmartProxy, not a URL string.
    def call
      result = run
      @proxy.update_columns(
        compatibility_status:     result[:status],
        compatibility_score:      result[:score],
        compatibility_report:     result[:report],
        compatibility_checked_at: Time.current
      )
    rescue => e
      Rails.logger.error "[CompatibilityScanner] proxy=#{@proxy&.id} error=#{e.message}"
      @proxy&.update_columns(
        compatibility_status:     "incompatible",
        compatibility_score:      0,
        compatibility_report:     { checked_url: @url, error: e.message },
        compatibility_checked_at: Time.current
      )
    end

    # Runs the analysis and returns the result hash without touching the DB.
    # Safe to call when initialized with a URL string.
    def run
      analyze
    end

    private

    def analyze
      fetch  = fetch_with_redirects(@url)
      score  = 100
      risks  = []
      notes  = []

      if fetch[:error]
        return build_result(
          score:  0,
          status: "incompatible",
          fetch:  fetch,
          risks:  ["fetch_error"],
          notes:  [fetch[:error]]
        )
      end

      http_status     = fetch[:status]
      content_type    = fetch[:content_type].to_s
      headers         = fetch[:headers]
      body            = fetch[:body].to_s
      redirects_count = fetch[:redirects_count]

      # ── HTTP status ────────────────────────────────────────────────────────
      if http_status >= 500
        score -= 40; risks << "server_error"
        notes << "HTTP #{http_status}"
      elsif http_status >= 400
        score -= 30; risks << "client_error"
        notes << "HTTP #{http_status}"
      end

      # ── Excessive redirects ────────────────────────────────────────────────
      if redirects_count > 3
        score -= 10; risks << "excessive_redirects"
        notes << "#{redirects_count} redirects"
      end

      # ── Bot protection ─────────────────────────────────────────────────────
      bot_signals = detect_bot_protection(headers, body)
      if bot_signals.any?
        score -= 50; risks << "bot_protection"
        notes << "Bot protection: #{bot_signals.join(', ')}"
      end

      # ── Content-Type ───────────────────────────────────────────────────────
      is_html = content_type.include?("text/html")
      unless is_html
        score -= 20; risks << "unexpected_content_type"
        notes << "Content-Type: #{content_type}"
      end

      # ── CSP frame-ancestors ────────────────────────────────────────────────
      csp = headers["content-security-policy"].to_s
      if csp.include?("frame-ancestors") && !csp.match?(/frame-ancestors[^;]*\*/)
        score -= 15; risks << "restrictive_csp"
        notes << "CSP restricts frame-ancestors"
      end

      # ── X-Frame-Options ────────────────────────────────────────────────────
      xfo = headers["x-frame-options"].to_s.upcase.strip
      if %w[DENY SAMEORIGIN].include?(xfo)
        score -= 15; risks << "x_frame_options"
        notes << "X-Frame-Options: #{xfo}"
      end

      # ── Framework detection + Next.js checks ──────────────────────────────
      detected_framework = nil
      if body.include?("__NEXT_DATA__")
        detected_framework = "nextjs"
        if body.match?(/"assetPrefix"\s*:\s*"https?:\/\//)
          score -= 5; risks << "nextjs_absolute_asset_prefix"
          notes << "Next.js absolute assetPrefix"
        end
      end

      # ── Internal links ─────────────────────────────────────────────────────
      internal_links_count = 0
      if is_html
        internal_links_count = count_internal_links(body, fetch[:final_url])
        if internal_links_count < 3
          score -= 5
          notes << "Few internal links (#{internal_links_count})"
        end
      end

      score = score.clamp(0, 100)

      build_result(
        score:                score,
        fetch:                fetch,
        risks:                risks,
        notes:                notes,
        detected_framework:   detected_framework,
        internal_links_count: internal_links_count
      )
    end

    def build_result(score:, fetch:, risks:, notes:, status: nil,
                     detected_framework: nil, internal_links_count: 0)
      derived_status = status || case score
                                 when 80..100 then "compatible"
                                 when 50..79  then "partial"
                                 else              "incompatible"
                                 end
      {
        status: derived_status,
        score:  score,
        report: {
          checked_url:          @url,
          final_url:            fetch[:final_url],
          status:               fetch[:status],
          redirects_count:      fetch[:redirects_count],
          content_type:         fetch[:content_type],
          detected_framework:   detected_framework,
          detected_risks:       risks,
          internal_links_count: internal_links_count,
          notes:                notes
        }
      }
    end

    # ── HTTP fetch ─────────────────────────────────────────────────────────────

    def fetch_with_redirects(start_url)
      current_url     = start_url
      redirects_count = 0

      loop do
        uri  = URI.parse(current_url)
        http = build_http(uri)
        req  = build_request(uri)

        response = http.request(req)
        code     = response.code.to_i

        if [301, 302, 303, 307, 308].include?(code) && redirects_count < MAX_REDIRECTS
          location = response["location"]
          if location.present?
            current_url = URI.join(current_url, location).to_s
            redirects_count += 1
            next
          end
        end

        headers = {}
        response.each_header { |k, v| headers[k.downcase] = v }

        body = safe_encode(response.body.to_s)[0, MAX_BODY_BYTES]
        content_type = headers["content-type"].to_s.split(";").first.to_s.strip

        return {
          status:          code,
          final_url:       current_url,
          redirects_count: redirects_count,
          headers:         headers,
          content_type:    content_type,
          body:            body
        }
      end
    rescue => e
      {
        status:          nil,
        final_url:       current_url,
        redirects_count: redirects_count,
        headers:         {},
        content_type:    nil,
        body:            "",
        error:           e.message
      }
    end

    def build_http(uri)
      http              = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def build_request(uri)
      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"]      = "Mozilla/5.0 (compatible; UbycaCompatibilityScanner/1.0)"
      req["Accept"]          = "text/html,application/xhtml+xml,*/*"
      req["Accept-Language"] = "es,en;q=0.9"
      req
    end

    def safe_encode(str)
      str.encode("UTF-8", invalid: :replace, undef: :replace)
    rescue
      str.force_encoding("UTF-8")
    end

    # ── Bot protection detection ───────────────────────────────────────────────

    def detect_bot_protection(headers, body)
      signals = []
      body_lower = body.downcase

      signals << "cf-ray"      if headers["cf-ray"].present?
      signals << "cloudflare"  if headers["server"].to_s.downcase.include?("cloudflare")
      signals << "datadome"    if headers["x-datadome-cid"].present? || body_lower.include?("datadome")
      signals << "akamai"      if headers["x-akamai-request-id"].present? ||
                                  headers["x-check-cacheable"].present?

      BOT_BODY_SIGNALS.each do |signal|
        signals << signal if body_lower.include?(signal)
      end

      signals.uniq
    end

    # ── Internal links ─────────────────────────────────────────────────────────

    def count_internal_links(body, base_url)
      base_host = URI.parse(base_url.to_s).host
      return 0 unless base_host

      hrefs = body.scan(/href=["']([^"'#?][^"']*)["']/i).flatten

      hrefs.count do |href|
        if href.start_with?("/") && !href.start_with?("//")
          true
        elsif href.start_with?("http")
          URI.parse(href).host == base_host rescue false
        else
          false
        end
      end
    rescue
      0
    end
  end
end
