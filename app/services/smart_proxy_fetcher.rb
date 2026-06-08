require "net/http"
require "uri"
require "openssl"
require "zlib"
require "stringio"

# Fetches a remote URL server-side, rewrites internal URLs so they route through
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

  MAX_RESPONSE_BYTES = 10 * 1024 * 1024  # 10 MB
  CONNECT_TIMEOUT    = 10                # seconds
  READ_TIMEOUT       = 20                # seconds
  MAX_REDIRECTS      = 5

  HTML_TYPES = %w[text/html application/xhtml+xml].freeze
  CSS_TYPES  = %w[text/css].freeze

  Result = Struct.new(:success, :body, :content_type, :error, keyword_init: true)

  # @param smart_proxy [SmartProxy]
  # @param path        [String]  sub-path appended to destination_url
  # @param api_base    [String]  base URL used by the injected analytics script
  def initialize(smart_proxy, path, api_base)
    @smart_proxy  = smart_proxy
    @path         = path.to_s.delete_prefix("/")
    @api_base     = api_base
    @proxy_prefix = smart_proxy.proxy_path_prefix
  end

  def call
    target_url = build_target_url
    return Result.new(success: false, error: "invalid_destination_url") unless target_url

    response = fetch_with_redirects(target_url)
    return Result.new(success: false, error: "fetch_failed") unless response

    raw_ct  = response["content-type"].to_s
    ct_base = raw_ct.split(";").first.to_s.strip.downcase

    if HTML_TYPES.include?(ct_base)
      serve_html(response, target_url)
    elsif CSS_TYPES.include?(ct_base)
      serve_css(response, target_url)
    else
      serve_binary(response, raw_ct)
    end
  rescue => e
    Rails.logger.error "[SMART_PROXY_FETCHER] #{e.class}: #{e.message}"
    Result.new(success: false, error: "internal_error")
  end

  private

  # ── Content-type dispatch ──────────────────────────────────────────────────

  def serve_html(response, target_url)
    raw   = decompress(response)
    # Charset: HTTP header takes priority; fall back to scanning meta tags.
    cs    = extract_charset_from_header(response) || extract_charset_from_bytes(raw)
    html  = decode_to_utf8(raw, cs)
    html  = rewrite_html(html, target_url)
    html  = strip_inline_csp(html)
    html  = normalize_meta_charset(html)
    html  = inject_script(html)
    Result.new(success: true, body: html, content_type: "text/html; charset=utf-8")
  end

  def serve_css(response, target_url)
    source_uri  = URI.parse(target_url)
    base_origin = build_origin(source_uri)
    raw         = decompress(response)
    cs          = extract_charset_from_header(response)
    css         = decode_to_utf8(raw, cs)
    css         = rewrite_css(css, base_origin, source_uri)
    Result.new(success: true, body: css, content_type: "text/css; charset=utf-8")
  end

  def serve_binary(response, raw_ct)
    body = response.body.dup.force_encoding(Encoding::BINARY)
    Result.new(
      success:      true,
      body:         body,
      content_type: raw_ct.presence || "application/octet-stream"
    )
  end

  # ── Encoding ───────────────────────────────────────────────────────────────

  # Decompress gzip body if the server sent it despite Accept-Encoding: identity.
  def decompress(response)
    raw = response.body.dup.force_encoding(Encoding::BINARY)
    return raw unless response["content-encoding"].to_s.downcase.include?("gzip")

    Zlib::GzipReader.new(StringIO.new(raw)).read.force_encoding(Encoding::BINARY)
  rescue => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] gzip decompress failed: #{e.message}"
    raw
  end

  # Charset from HTTP Content-Type header, e.g. "text/html; charset=iso-8859-1".
  def extract_charset_from_header(response)
    m = response["content-type"].to_s.match(/charset\s*=\s*["']?([^"'\s;]+)/i)
    m ? normalize_charset(m[1]) : nil
  end

  # Charset from the first 2 KB of the body (meta tags).
  # Both UTF-8 and Latin-1 are ASCII-compatible in the ASCII range, so we can
  # decode the snippet as BINARY→UTF-8 with replacement just to scan the text.
  def extract_charset_from_bytes(raw_bytes)
    snippet = raw_bytes[0, 2048].to_s
              .encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)

    # <meta charset="iso-8859-1">  or  <meta charset=iso-8859-1>
    m = snippet.match(/<meta\b[^>]*\bcharset\s*=\s*["']?([^"'\s;>]+)/i)
    return normalize_charset(m[1]) if m

    # <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
    m = snippet.match(/<meta\b[^>]*\bcontent\s*=\s*["'][^"']*charset\s*=\s*([^"'\s;>]+)/i)
    m ? normalize_charset(m[1]) : nil
  end

  # Map common charset aliases to Ruby's Encoding names.
  def normalize_charset(cs)
    return nil unless cs
    case cs.strip.upcase
    when "UTF8"                             then "UTF-8"
    when "LATIN-1", "LATIN1"               then "ISO-8859-1"
    when "WIN-1252", "WINDOWS-1252", "CP1252" then "Windows-1252"
    when "WIN-1251", "WINDOWS-1251", "CP1251" then "Windows-1251"
    else cs.strip
    end
  end

  # Convert BINARY-tagged bytes to UTF-8.
  # body_bytes must be a BINARY (ASCII-8BIT) String — as returned by Net::HTTP streaming.
  # charset is the source encoding name (Ruby-compatible), or nil to assume UTF-8.
  def decode_to_utf8(body_bytes, charset)
    charset ||= "UTF-8"
    # force_encoding reinterprets the bytes without any conversion —
    # it just changes the Ruby encoding tag so encode() knows what to convert FROM.
    body_bytes.dup
              .force_encoding(charset)
              .encode("UTF-8", invalid: :replace, undef: :replace)
  rescue => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] decode_to_utf8 (#{charset}): #{e.message}"
    body_bytes.dup
              .force_encoding(Encoding::BINARY)
              .encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)
  end

  # ── HTML rewriting ─────────────────────────────────────────────────────────

  def rewrite_html(html, source_url)
    source_uri  = URI.parse(source_url)
    base_origin = build_origin(source_uri)

    # Remove <base> — the proxy URL must serve as the implicit base.
    html = html.gsub(/<base\b[^>]*>/i, "")

    # Rewrite URL-bearing attributes.
    # Covers standard attrs + common lazy-load patterns (data-src, data-bg, poster).
    html = html.gsub(/(\s(?:href|src|action|data-src|data-bg|poster)\s*=\s*)(["'])(.*?)\2/im) do
      "#{$1}#{$2}#{rewrite_url($3, base_origin, source_uri)}#{$2}"
    end

    # srcset / data-srcset: "url1 1x, url2 2x" or "url1 320w, url2 640w"
    html = html.gsub(/(\s(?:srcset|data-srcset)\s*=\s*)(["'])(.*?)\2/im) do
      "#{$1}#{$2}#{rewrite_srcset($3, base_origin, source_uri)}#{$2}"
    end

    # style="..." attributes — rewrite url() inside inline styles.
    html = html.gsub(/(\bstyle\s*=\s*)(["'])(.*?)\2/im) do
      "#{$1}#{$2}#{rewrite_css_urls($3, base_origin, source_uri)}#{$2}"
    end

    # <style>...</style> blocks.
    html.gsub(/(<style\b[^>]*>)(.*?)(<\/style>)/im) do
      "#{$1}#{rewrite_css_urls($2, base_origin, source_uri)}#{$3}"
    end
  end

  def rewrite_url(url, base_origin, source_uri)
    url = url.to_s.strip
    return url if url.empty?
    return url if url.start_with?("data:", "mailto:", "tel:", "javascript:", "#", "blob:")

    if url.start_with?("//")
      # Protocol-relative — treat as HTTPS for origin check.
      u = URI.parse("https:#{url}") rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxy_path(u) : url

    elsif url.start_with?("https://", "http://")
      u = URI.parse(url) rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxy_path(u) : url

    elsif url.start_with?("/")
      "#{@proxy_prefix}#{url}"

    else
      # Relative URL (./path, ../path, or bare relative like "images/logo.png").
      # Resolve against the source page URL so the browser doesn't have to —
      # this avoids path-prefix ambiguity when the proxy root has no trailing slash.
      u = URI.join(source_uri, url) rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxy_path(u) : u.to_s
    end
  end

  def rewrite_srcset(srcset, base_origin, source_uri)
    srcset.split(",").map do |entry|
      parts    = entry.strip.split(/\s+/, 2)
      parts[0] = rewrite_url(parts[0].to_s, base_origin, source_uri) if parts[0]
      parts.join(" ")
    end.join(", ")
  end

  # ── CSS rewriting ──────────────────────────────────────────────────────────

  # Rewrite a complete CSS file: url() references and @import directives.
  def rewrite_css(css, base_origin, source_uri)
    css = rewrite_css_urls(css, base_origin, source_uri)

    # @import "url"  or  @import 'url'  (without url() wrapper)
    css.gsub(/@import\s+(["'])(.*?)\1/m) do
      "@import #{$1}#{rewrite_url($2, base_origin, source_uri)}#{$1}"
    end
  end

  # Rewrite url(...) occurrences in any CSS string (files, <style> blocks, inline styles).
  # Handles quoted (single/double) and unquoted values.
  def rewrite_css_urls(css, base_origin, source_uri)
    css.gsub(/url\(\s*(["']?)(.*?)\1\s*\)/m) do
      quote = $1
      url   = $2.strip
      "url(#{quote}#{rewrite_url(url, base_origin, source_uri)}#{quote})"
    end
  end

  # ── HTML cleanup ───────────────────────────────────────────────────────────

  # Strip inline Content-Security-Policy meta tags.
  # The origin site's CSP would block the injected analytics script.
  def strip_inline_csp(html)
    html.gsub(/<meta\b[^>]*\bhttp-equiv\s*=\s*["']?content-security-policy["']?\b[^>]*>/i, "")
  end

  # After converting to UTF-8, update any <meta charset> declarations so the
  # browser's HTML parser doesn't re-interpret the page with the old encoding.
  def normalize_meta_charset(html)
    # <meta charset="...">
    html = html.gsub(/<meta\b([^>]*)\bcharset\s*=\s*["']?[^"'\s;>]+["']?([^>]*)>/i) do
      "<meta#{$1}charset=\"utf-8\"#{$2}>"
    end

    # <meta http-equiv="Content-Type" content="text/html; charset=...">
    html.gsub(/(content\s*=\s*["'][^"']*)charset\s*=\s*[^"'\s;]+/i) do
      "#{$1}charset=utf-8"
    end
  end

  # ── URL helpers ────────────────────────────────────────────────────────────

  def build_origin(uri)
    o = "#{uri.scheme}://#{uri.host}"
    o += ":#{uri.port}" unless default_port?(uri)
    o
  end

  def proxy_path(uri)
    "#{@proxy_prefix}#{uri.path}#{query_string(uri)}"
  end

  def same_origin?(uri, base_origin)
    build_origin(uri) == base_origin
  end

  def default_port?(uri)
    (uri.scheme == "https" && uri.port == 443) ||
      (uri.scheme == "http"  && uri.port == 80)
  end

  def query_string(uri)
    uri.query ? "?#{uri.query}" : ""
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────

  def build_target_url
    base = @smart_proxy.destination_url.chomp("/")
    @path.present? ? "#{base}/#{@path}" : base
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

  def fetch_with_redirects(url, count = 0)
    return nil if count > MAX_REDIRECTS

    uri = URI.parse(url) rescue nil
    return nil unless uri && secure_uri?(uri)

    response = http_get(uri)
    return nil unless response

    if response.is_a?(Net::HTTPRedirection)
      location = response["location"].to_s.strip
      return nil if location.empty?
      next_url = location.start_with?("http") ? location : URI.join(url, location).to_s
      fetch_with_redirects(next_url, count + 1)
    else
      response
    end
  rescue URI::InvalidURIError => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] Invalid URI: #{e.message}"
    nil
  end

  def http_get(uri)
    use_ssl   = uri.is_a?(URI::HTTPS)
    remaining = MAX_RESPONSE_BYTES

    Net::HTTP.start(uri.host, uri.port,
      use_ssl:      use_ssl,
      open_timeout: CONNECT_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      verify_mode:  OpenSSL::SSL::VERIFY_PEER
    ) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"]      = "Mozilla/5.0 (compatible; Ubyca-SmartProxy/1.0)"
      req["Accept"]          = "*/*"
      req["Accept-Language"] = "es,en;q=0.9"
      # Explicitly disable compression so we get raw bytes.
      # Some servers ignore this and send gzip anyway — decompress() handles it.
      req["Accept-Encoding"] = "identity"

      body = String.new("", encoding: Encoding::BINARY)
      http.request(req) do |resp|
        resp.read_body do |chunk|
          remaining -= chunk.bytesize
          if remaining < 0
            Rails.logger.warn "[SMART_PROXY_FETCHER] Response body too large, truncating"
            body << chunk[0, chunk.bytesize + remaining]
            break
          end
          body << chunk
        end
        resp.instance_variable_set(:@body, body)
        resp.instance_variable_set(:@read, true)
        return resp
      end
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] Timeout: #{e.message}"
    nil
  rescue OpenSSL::SSL::SSLError => e
    Rails.logger.warn "[SMART_PROXY_FETCHER] SSL error: #{e.message}"
    nil
  rescue => e
    Rails.logger.error "[SMART_PROXY_FETCHER] HTTP error: #{e.class}: #{e.message}"
    nil
  end

  # ── Script injection ───────────────────────────────────────────────────────

  def inject_script(html)
    script = build_script
    if    html.include?("</body>") then html.sub("</body>", "#{script}\n</body>")
    elsif html.include?("</head>") then html.sub("</head>", "#{script}\n</head>")
    else  html + "\n" + script
    end
  end

  def build_script
    org      = @smart_proxy.organization
    proxy_id = @smart_proxy.id
    org_slug = org.slug
    slug     = @smart_proxy.slug
    api_base = @api_base

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
          lastPos:   null,
          watchId:   null
        };

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
              if (_firstFix) {
                _firstFix = false;
                track('smart_proxy_location_granted', _u.lastPos);
              }
            },
            function() {
              if (_firstFix) { _firstFix = false; track('smart_proxy_location_denied'); }
            },
            { enableHighAccuracy: false, timeout: 10000, maximumAge: 30000 }
          );
        } else {
          track('smart_proxy_location_denied');
        }

        track('smart_proxy_opened');

        var _startMs = Date.now();
        var _hbInterval = setInterval(function() {
          var gps = _u.lastPos ? {
            latitude:  _u.lastPos.latitude,
            longitude: _u.lastPos.longitude,
            accuracy:  _u.lastPos.accuracy
          } : {};
          track('smart_proxy_heartbeat', gps);
        }, 30000);

        document.addEventListener('visibilitychange', function() {
          track(document.hidden ? 'smart_proxy_page_hidden' : 'smart_proxy_page_visible');
        });

        document.addEventListener('click', function(e) {
          var t = e.target || {};
          track('smart_proxy_click', {
            tag:  (t.tagName || '').toLowerCase(),
            href: t.href  || null,
            text: (t.innerText || t.textContent || '').trim().slice(0, 100)
          });
        });

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
end
