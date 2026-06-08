require "net/http"
require "uri"
require "openssl"

# Fetches a remote URL server-side, rewrites internal URLs so they go through
# the proxy, and injects the Ubyca analytics script before </body>.
#
# Security guardrails:
#   - Only http:// and https:// are allowed.
#   - Localhost and RFC-1918 / loopback addresses are blocked.
#   - Connection and read timeouts prevent hanging requests.
#   - Response body size is capped at MAX_RESPONSE_BYTES.
class SmartProxyFetcher
  BLOCKED_HOSTS = %w[localhost 127.0.0.1 ::1 0.0.0.0].freeze
  PRIVATE_IP_PATTERNS = [
    /\A10\.\d+\.\d+\.\d+\z/,
    /\A172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\z/,
    /\A192\.168\.\d+\.\d+\z/,
    /\A169\.254\.\d+\.\d+\z/,
    /\Afc[0-9a-f]{2}:/i,
    /\Afd[0-9a-f]{2}:/i
  ].freeze

  MAX_RESPONSE_BYTES = 5 * 1024 * 1024  # 5 MB
  CONNECT_TIMEOUT    = 10               # seconds
  READ_TIMEOUT       = 15               # seconds
  MAX_REDIRECTS      = 3

  Result = Struct.new(:success, :body, :content_type, :error, keyword_init: true)

  # @param smart_proxy [SmartProxy]
  # @param path        [String]  sub-path from the request (e.g. "products/item")
  # @param api_base    [String]  base URL of the Ubyca API (e.g. "https://go.ubyca.com")
  def initialize(smart_proxy, path, api_base)
    @smart_proxy = smart_proxy
    @path        = path.to_s.delete_prefix("/")
    @api_base    = api_base
    @proxy_prefix = smart_proxy.proxy_path_prefix
  end

  def call
    target_url = build_target_url
    unless target_url
      return Result.new(success: false, error: "invalid_destination_url")
    end

    response = fetch_with_redirects(target_url)
    unless response
      return Result.new(success: false, error: "fetch_failed")
    end

    content_type = (response["content-type"] || "text/html").split(";").first.strip

    if content_type == "text/html"
      charset = extract_charset(response)
      raw     = force_utf8(response.body, charset)
      html    = rewrite_html(raw, target_url)
      html    = inject_script(html)
      Result.new(success: true, body: html, content_type: "text/html; charset=utf-8")
    else
      Result.new(success: true, body: response.body, content_type: response["content-type"])
    end
  rescue => e
    Rails.logger.error "[SMART_PROXY_FETCHER] #{e.class}: #{e.message}"
    Result.new(success: false, error: "internal_error")
  end

  private

  def build_target_url
    base = @smart_proxy.destination_url.chomp("/")
    if @path.present?
      "#{base}/#{@path}"
    else
      base
    end
  rescue
    nil
  end

  def secure_uri?(uri)
    return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    host = uri.host.to_s.downcase
    return false if BLOCKED_HOSTS.include?(host)
    return false if PRIVATE_IP_PATTERNS.any? { |p| p.match?(host) }
    true
  end

  def fetch_with_redirects(url, redirect_count = 0)
    return nil if redirect_count > MAX_REDIRECTS

    uri = URI.parse(url)
    return nil unless secure_uri?(uri)

    response = http_get(uri)
    return nil unless response

    if response.is_a?(Net::HTTPRedirection)
      location = response["location"].to_s.strip
      return nil if location.empty?
      next_uri = location.start_with?("http") ? URI.parse(location) : URI.join(url, location)
      fetch_with_redirects(next_uri.to_s, redirect_count + 1)
    else
      response
    end
  rescue URI::InvalidURIError => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] Invalid redirect URI: #{e.message}"
    nil
  end

  def http_get(uri)
    use_ssl   = uri.is_a?(URI::HTTPS)
    port      = uri.port || (use_ssl ? 443 : 80)
    remaining = MAX_RESPONSE_BYTES

    Net::HTTP.start(uri.host, port,
      use_ssl:      use_ssl,
      open_timeout: CONNECT_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      verify_mode:  OpenSSL::SSL::VERIFY_PEER
    ) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"]      = "Ubyca-SmartProxy/1.0"
      req["Accept"]          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      req["Accept-Language"] = "es,en;q=0.5"

      # Stream response to enforce size limit without loading everything into memory.
      body = String.new("", encoding: "BINARY")
      http.request(req) do |resp|
        resp.read_body do |chunk|
          remaining -= chunk.bytesize
          if remaining < 0
            Rails.logger.warn "[SMART_PROXY_FETCHER] Response too large, truncating"
            body << chunk[0, chunk.bytesize + remaining]
            break
          end
          body << chunk
        end
        # Attach body to response object so caller can read it normally.
        resp.instance_variable_set(:@body, body)
        resp.instance_variable_set(:@read, true)
        return resp
      end
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] Timeout fetching #{uri}: #{e.message}"
    nil
  rescue OpenSSL::SSL::SSLError => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] SSL error fetching #{uri}: #{e.message}"
    nil
  rescue => e
    Rails.logger.error "[SMART_PROXY_FETCHER] HTTP error fetching #{uri}: #{e.class}: #{e.message}"
    nil
  end

  # ── HTML rewriting ─────────────────────────────────────────────────────────

  def rewrite_html(html, source_url)
    source_uri  = URI.parse(source_url)
    base_origin = "#{source_uri.scheme}://#{source_uri.host}"
    base_origin += ":#{source_uri.port}" unless default_port?(source_uri)

    # Remove any <base> tag — it would confuse the browser's relative URL resolution.
    html = html.gsub(/<base\b[^>]*>/i, "")

    # Rewrite href, src, action attributes (handles single + double quotes).
    html = html.gsub(/(\s(?:href|src|action)\s*=\s*)(["'])(.*?)\2/im) do
      attr_eq = $1
      quote   = $2
      url     = $3
      new_url = rewrite_url(url, base_origin, source_uri)
      "#{attr_eq}#{quote}#{new_url}#{quote}"
    end

    # Rewrite srcset (comma-separated "url [descriptor]" pairs).
    html.gsub(/(\ssrcset\s*=\s*)(["'])(.*?)\2/im) do
      attr_eq = $1
      quote   = $2
      srcset  = $3
      new_srcset = rewrite_srcset(srcset, base_origin, source_uri)
      "#{attr_eq}#{quote}#{new_srcset}#{quote}"
    end
  end

  def rewrite_url(url, base_origin, source_uri)
    url = url.to_s.strip
    return url if url.empty?
    return url if url.start_with?("data:", "mailto:", "tel:", "javascript:", "#")

    if url.start_with?("//")
      # Protocol-relative → treat as HTTPS and check domain.
      full_url = "https:#{url}"
      begin
        u = URI.parse(full_url)
        same_origin = same_origin?(u, base_origin)
        same_origin ? "#{@proxy_prefix}#{u.path}#{query_string(u)}" : url
      rescue URI::InvalidURIError
        url
      end

    elsif url.start_with?("https://", "http://")
      begin
        u = URI.parse(url)
        same_origin?(u, base_origin) ? "#{@proxy_prefix}#{u.path}#{query_string(u)}" : url
      rescue URI::InvalidURIError
        url
      end

    elsif url.start_with?("/")
      # Root-relative → prefix with proxy path.
      "#{@proxy_prefix}#{url}"

    else
      # Relative URL — the browser resolves it relative to the current proxy URL,
      # which already has the proxy prefix, so no rewriting needed.
      url
    end
  end

  def rewrite_srcset(srcset, base_origin, source_uri)
    srcset.split(",").map do |entry|
      parts    = entry.strip.split(/\s+/, 2)
      new_url  = rewrite_url(parts[0], base_origin, source_uri)
      parts[0] = new_url
      parts.join(" ")
    end.join(", ")
  end

  def same_origin?(uri, base_origin)
    candidate = "#{uri.scheme}://#{uri.host}"
    candidate += ":#{uri.port}" unless default_port?(uri)
    candidate == base_origin
  end

  def default_port?(uri)
    (uri.scheme == "https" && uri.port == 443) ||
      (uri.scheme == "http" && uri.port == 80)
  end

  def query_string(uri)
    uri.query ? "?#{uri.query}" : ""
  end

  # ── Script injection ───────────────────────────────────────────────────────

  def inject_script(html)
    script = build_script
    # Prefer injecting before </body>; fall back to before </head> or appending.
    if html.include?("</body>")
      html.sub("</body>", "#{script}\n</body>")
    elsif html.include?("</head>")
      html.sub("</head>", "#{script}\n</head>")
    else
      html + "\n" + script
    end
  end

  def build_script
    org      = @smart_proxy.organization
    proxy_id = @smart_proxy.id
    org_slug = org.slug
    slug     = @smart_proxy.slug
    api_base = @api_base

    # HEARTBEAT_INTERVAL must be shorter than SmartProxyLiveVisit::ACTIVE_WINDOW (45 s)
    # so every live-visit record stays within the active window between beats.
    # 30 s matches the same cadence used by Experiences for GeoPointLiveVisit.
    <<~HTML
      <script>
      (function(){
        var _u = {
          sessionId: (function(){
            var k = '_ubyca_sp_session';
            try {
              var s = localStorage.getItem(k);
              if (!s) {
                s = (typeof crypto !== 'undefined' && crypto.randomUUID)
                      ? crypto.randomUUID()
                      : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                          var r = Math.random() * 16 | 0;
                          return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
                        });
                localStorage.setItem(k, s);
              }
              return s;
            } catch(e) {
              return Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
            }
          })(),
          proxyId:   #{proxy_id.to_json},
          orgSlug:   #{org_slug.to_json},
          proxySlug: #{slug.to_json},
          host:      window.location.hostname,
          apiBase:   #{api_base.to_json},
          lastPos:   null,   // updated by watchPosition on every fix
          watchId:   null
        };

        // ── Analytics event sender ────────────────────────────────────────────
        function track(evt, data) {
          var payload = Object.assign({
            event_type:     evt,
            session_id:     _u.sessionId,
            smart_proxy_id: _u.proxyId,
            org_slug:       _u.orgSlug,
            proxy_slug:     _u.proxySlug,
            host:           _u.host
          }, data || {});
          fetch(_u.apiBase + '/api/public/smart_proxy_events', {
            method:    'POST',
            headers:   { 'Content-Type': 'application/json' },
            body:      JSON.stringify(payload),
            keepalive: true
          }).catch(function(){});
        }

        // ── GPS — continuous watchPosition (same strategy as Experiences) ─────
        // watchPosition keeps _u.lastPos current so every heartbeat carries
        // fresh coordinates.  This feeds SmartProxyLiveVisit (live visits),
        // analytics_events.latitude/longitude (hotspots), and GPS intensity.
        track('smart_proxy_location_requested');

        if (navigator.geolocation) {
          var _firstFix = true;

          _u.watchId = navigator.geolocation.watchPosition(
            function(pos) {
              _u.lastPos = {
                latitude:  pos.coords.latitude,
                longitude: pos.coords.longitude,
                accuracy:  pos.coords.accuracy
              };
              // Report granted only once (first fix).
              if (_firstFix) {
                _firstFix = false;
                track('smart_proxy_location_granted', _u.lastPos);
              }
            },
            function() {
              if (_firstFix) {
                _firstFix = false;
                track('smart_proxy_location_denied');
              }
            },
            { enableHighAccuracy: false, timeout: 10000, maximumAge: 30000 }
          );
        } else {
          track('smart_proxy_location_denied');
        }

        // ── Page opened ───────────────────────────────────────────────────────
        track('smart_proxy_opened');

        // ── Heartbeat every 30 s ──────────────────────────────────────────────
        // Includes latest GPS fix so the server can upsert SmartProxyLiveVisit
        // with last_seen_at refreshed — identical to the live-visit heartbeat
        // used by Experiences (POST /api/public/geo_points/:id/live_visit).
        var _startMs = Date.now();
        var _hbInterval = setInterval(function() {
          var gps = _u.lastPos ? {
            latitude:  _u.lastPos.latitude,
            longitude: _u.lastPos.longitude,
            accuracy:  _u.lastPos.accuracy
          } : {};
          track('smart_proxy_heartbeat', gps);
        }, 30000);

        // ── Visibility ────────────────────────────────────────────────────────
        document.addEventListener('visibilitychange', function() {
          track(document.hidden ? 'smart_proxy_page_hidden' : 'smart_proxy_page_visible');
        });

        // ── Click tracking ────────────────────────────────────────────────────
        document.addEventListener('click', function(e) {
          var t = e.target || {};
          track('smart_proxy_click', {
            tag:  (t.tagName || '').toLowerCase(),
            href: t.href  || null,
            text: (t.innerText || t.textContent || '').trim().slice(0, 100)
          });
        });

        // ── Cleanup and dwell on unload ───────────────────────────────────────
        window.addEventListener('pagehide', function() {
          clearInterval(_hbInterval);
          if (_u.watchId !== null) navigator.geolocation.clearWatch(_u.watchId);
          track('smart_proxy_dwell_completed', {
            dwell_seconds: Math.round((Date.now() - _startMs) / 1000)
          });
        });
      })();
      </script>
    HTML
  end

  # ── Encoding helpers ───────────────────────────────────────────────────────

  def extract_charset(response)
    ct = response["content-type"].to_s
    ct[/charset\s*=\s*([^\s;]+)/i, 1]&.strip&.upcase
  end

  def force_utf8(body, charset)
    return body.encode("UTF-8", invalid: :replace, undef: :replace) if charset.nil? || charset == "UTF-8"
    body.encode("UTF-8", charset, invalid: :replace, undef: :replace)
  rescue Encoding::ConverterNotFoundError
    body.encode("UTF-8", invalid: :replace, undef: :replace)
  end
end
