require "net/http"
require "uri"
require "openssl"
require "zlib"
require "stringio"
require "digest"

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
  CACHE_TTL          = 1.hour

  HTML_TYPES = %w[text/html application/xhtml+xml].freeze
  FONT_MIMES = %w[font/woff font/woff2 font/ttf font/otf
                  application/vnd.ms-fontobject application/x-font-woff
                  application/x-font-ttf application/font-woff application/font-woff2].freeze

  # URL extensions that must never be processed as HTML.
  # Keyed by extension (lowercase, with dot), value is the fallback MIME type used
  # when the origin returns text/html instead of the correct asset type.
  ASSET_EXTENSIONS = {
    ".css"   => "text/css",
    ".js"    => "application/javascript",
    ".mjs"   => "application/javascript",
    ".cjs"   => "application/javascript",
    ".ts"    => "application/typescript",
    ".map"   => "application/json",
    ".json"  => "application/json",
    ".xml"   => "application/xml",
    ".txt"   => "text/plain",
    ".png"   => "image/png",
    ".jpg"   => "image/jpeg",
    ".jpeg"  => "image/jpeg",
    ".gif"   => "image/gif",
    ".svg"   => "image/svg+xml",
    ".webp"  => "image/webp",
    ".avif"  => "image/avif",
    ".ico"   => "image/x-icon",
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf"   => "font/ttf",
    ".otf"   => "font/otf",
    ".eot"   => "application/vnd.ms-fontobject",
    ".pdf"   => "application/pdf",
    ".mp4"   => "video/mp4",
    ".webm"  => "video/webm",
    ".mp3"   => "audio/mpeg",
    ".ogg"   => "audio/ogg",
  }.freeze

  Result = Struct.new(:success, :body, :content_type, :error, keyword_init: true)

  # @param smart_proxy [SmartProxy]
  # @param path        [String]  sub-path appended to destination_url
  # @param api_base    [String]  base URL used by the injected analytics script
  def initialize(smart_proxy, path, api_base)
    @smart_proxy     = smart_proxy
    @path            = path.to_s.delete_prefix("/")
    @api_base        = api_base
    @proxy_prefix    = smart_proxy.proxy_path_prefix
    @cdn_prefix_used = nil  # set by build_target_url when CDN branch is taken
  end

  def call
    target_url = build_target_url
    unless target_url
      Rails.logger.error "[SP_FETCHER] invalid_destination_url proxy_id=#{@smart_proxy.id} path=#{@path.inspect}"
      return Result.new(success: false, error: "invalid_destination_url")
    end

    # Resolve expected MIME from URL extension BEFORE fetching.
    # HTML pages have no known extension, so ext_mime is nil for them.
    ext_mime = asset_mime_for_url(target_url)

    # Classify Next.js static resource requests for diagnostics.
    next_resource_type =
      if    target_url.include?("/_next/static/css/")    then "NEXT_CSS"
      elsif target_url.include?("/_next/static/chunks/") then "NEXT_CHUNK"
      elsif target_url.include?("/_next/static/media/")  then "NEXT_MEDIA"
      elsif target_url.include?("/_next/")               then "NEXT_OTHER"
      end
    # NEXT_STATIC_REQUEST is logged post-fetch (below) to include status + content_type.

    # For static assets, check the server-side cache before hitting origin.
    if ext_mime
      Rails.logger.info "[SP_FETCHER] CACHE_STORE_CLASS #{Rails.cache.class.name}"
      Rails.logger.info "[SP_FETCHER] FONT_REQUEST target=#{target_url.inspect}" if FONT_MIMES.include?(ext_mime)
      cached = load_from_cache(target_url)
      if cached
        Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_HIT target=#{target_url.inspect}"
        Rails.logger.info "[SP_FETCHER] FONT_CACHE_HIT target=#{target_url.inspect}" if FONT_MIMES.include?(ext_mime)
        return cached
      end
      Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_MISS target=#{target_url.inspect}"
    end

    Rails.logger.info "[SP_FETCHER] FETCH target=#{target_url.inspect} " \
                      "ext_mime=#{ext_mime.inspect} " \
                      "proxy_prefix=#{@proxy_prefix.inspect}"

    response = fetch_with_redirects(target_url)
    unless response
      if next_resource_type
        Rails.logger.error "[SP_FETCHER] NEXT_STATIC_FETCH_FAILED " \
                           "type=#{next_resource_type} " \
                           "path=#{@path.inspect} " \
                           "cdn_prefix=#{@cdn_prefix_used.inspect} " \
                           "target_url=#{target_url.inspect}"
      end
      Rails.logger.error "[SP_FETCHER] fetch_failed target=#{target_url.inspect}"
      return Result.new(success: false, error: "fetch_failed")
    end

    raw_ct  = response["content-type"].to_s
    ct_base = raw_ct.split(";").first.to_s.strip.downcase

    Rails.logger.info "[SP_FETCHER] ORIGIN status=#{response.code} " \
                      "content_type=#{raw_ct.inspect} " \
                      "ct_base=#{ct_base.inspect} " \
                      "target=#{target_url.inspect}"

    if next_resource_type
      Rails.logger.info "[SP_FETCHER] NEXT_STATIC_REQUEST " \
                        "type=#{next_resource_type} " \
                        "path=#{@path.inspect} " \
                        "cdn_prefix=#{@cdn_prefix_used.inspect} " \
                        "target_url=#{target_url.inspect} " \
                        "status=#{response.code} " \
                        "content_type=#{response['content-type'].inspect}"
    end

    if next_resource_type && !%w[200 206].include?(response.code)
      body_preview_non2xx = response.body.to_s.dup
                                    .force_encoding("BINARY")
                                    .encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)[0, 200]
      Rails.logger.warn "[SP_FETCHER] NEXT_RESOURCE_MISSING " \
                        "type=#{next_resource_type} " \
                        "status=#{response.code} " \
                        "target=#{target_url.inspect} " \
                        "ct=#{raw_ct.inspect} " \
                        "body_bytes=#{response.body.to_s.bytesize} " \
                        "body_preview=#{body_preview_non2xx.inspect}"
    end

    result = if ext_mime
      if ct_base == "text/html"
        Rails.logger.warn "[SP_FETCHER] ASSET_HTML_MISMATCH target=#{target_url.inspect} " \
                          "origin_ct=#{raw_ct.inspect} returning empty body with ext_mime=#{ext_mime.inspect}"
        if ext_mime == "text/css"
          proxied_url = "#{@proxy_prefix}/#{@path}"
          Rails.logger.warn "[SP_FETCHER] smart_proxy_css_mime_mismatch " \
                            "original_url=#{target_url.inspect} " \
                            "proxied_url=#{proxied_url.inspect} " \
                            "content_type=#{raw_ct.inspect} " \
                            "status=#{response.code}"
          Rails.logger.warn "[SP_FETCHER] CSS_RESPONSE " \
                            "target=#{target_url.inspect} " \
                            "origin_status=#{response.code} " \
                            "origin_ct=#{raw_ct.inspect} " \
                            "body_bytes=0 (HTML_MISMATCH — stylesheet returned error page)"
        end
        if ext_mime&.match?(/javascript|typescript/)
          proxied_url  = "#{@proxy_prefix}/#{@path}"
          body_preview = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace)[0, 300]
          Rails.logger.warn "[SP_FETCHER] smart_proxy_js_mime_mismatch " \
                            "path=#{@path.inspect} " \
                            "original_url=#{target_url.inspect} " \
                            "proxied_url=#{proxied_url.inspect} " \
                            "status=#{response.code} " \
                            "content_type=#{raw_ct.inspect} " \
                            "cdn_prefix=#{@cdn_prefix_used.inspect} " \
                            "body_preview=#{body_preview.inspect}"
        end
        Result.new(success: true, body: "", content_type: ext_mime)
      elsif ext_mime == "text/css" && ct_base == "text/css"
        # CSS files need URL rewriting so that font references (url() in @font-face,
        # @import, etc.) point through the proxy instead of the bare origin.
        # Direct requests from the browser to the origin for fonts trigger CORS errors.
        Rails.logger.info "[SP_FETCHER] CSS_REWRITE target=#{target_url.inspect}"
        serve_css(response, target_url)
      elsif ext_mime&.match?(/javascript|typescript/) &&
            response.body.to_s.dup.force_encoding("BINARY")
                        .encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)[0, 50]
                        .strip.start_with?("<")
        # CDN returned HTML with a non-text/html content-type (bot challenge, auth
        # redirect that preserved the original MIME, etc.).  ct_base check above only
        # catches the text/html case; this catches everything else where the body IS
        # HTML regardless of the declared content-type.
        # Serving HTML as JS causes "Unexpected token '<'" → React cannot hydrate →
        # CSS-in-JS / CSS module injection never runs → default serif font wins.
        body_preview = response.body.to_s.dup.force_encoding("BINARY")
                                   .encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)[0, 300]
        proxied_url  = "#{@proxy_prefix}/#{@path}"
        Rails.logger.warn "[SP_FETCHER] smart_proxy_js_html_body " \
                          "path=#{@path.inspect} " \
                          "original_url=#{target_url.inspect} " \
                          "proxied_url=#{proxied_url.inspect} " \
                          "status=#{response.code} " \
                          "content_type=#{raw_ct.inspect} " \
                          "cdn_prefix=#{@cdn_prefix_used.inspect} " \
                          "body_preview=#{body_preview.inspect}"
        Result.new(success: true, body: "", content_type: ext_mime)
      else
        Rails.logger.info "[SP_FETCHER] BINARY_ASSET target=#{target_url.inspect} ct=#{raw_ct.inspect}"
        serve_binary(response, raw_ct.presence || ext_mime)
      end
    elsif HTML_TYPES.include?(ct_base)
      Rails.logger.info "[SP_FETCHER] HTML_PAGE target=#{target_url.inspect}"
      serve_html(response, target_url)
    else
      Rails.logger.info "[SP_FETCHER] BINARY_OTHER target=#{target_url.inspect} ct=#{raw_ct.inspect}"
      serve_binary(response, raw_ct.presence || "application/octet-stream")
    end

    if FONT_MIMES.include?(ext_mime.to_s)
      Rails.logger.info "[SP_FETCHER] FONT_RESPONSE content_type=#{result.content_type.inspect} " \
                        "body_bytes=#{result.body.to_s.bytesize} " \
                        "target=#{target_url.inspect}"
    end

    # Persist successful asset responses. Skip when origin returned an HTML error page
    # (empty body) and skip all HTML pages — those are never cached.
    if ext_mime && result.success && ct_base != "text/html"
      store_in_cache(target_url, result)
    else
      Rails.logger.info "[SP_FETCHER] CACHE_SKIP_STORE " \
                        "ext_mime=#{ext_mime.inspect} " \
                        "success=#{result.success} " \
                        "ct_base=#{ct_base.inspect} " \
                        "target=#{target_url.inspect}"
    end

    result
  rescue => e
    Rails.logger.error "[SP_FETCHER] EXCEPTION #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    Result.new(success: false, error: "internal_error")
  end

  private

  # ── Content-type dispatch ──────────────────────────────────────────────────

  # Rewrite CSS url() and @import so that font and image references inside
  # .css files point through the proxy instead of the bare origin.
  # Without this, @font-face src URLs hit the origin directly → CORS error.
  def serve_css(response, target_url)
    source_uri  = URI.parse(target_url)
    base_origin = build_origin(source_uri)
    raw         = decompress(response)
    cs          = extract_charset_from_header(response)
    css         = decode_to_utf8(raw, cs)

    # Count font-face src URLs before rewriting for diagnostic comparison.
    font_refs_before = css.scan(/url\s*\(\s*["']?[^"')]*\.(?:woff2?|ttf|otf|eot)/i).length

    css = rewrite_css(css, base_origin, source_uri)

    # Count how many font src URLs ended up proxified vs staying external.
    font_refs_proxified = css.scan(/url\s*\(\s*["']?#{Regexp.escape(@proxy_prefix)}/i).length
    font_refs_external  = css.scan(/url\s*\(\s*["']?https?:\/\//i)
                              .count { |u| !u.include?(@proxy_prefix) }

    font_family_lato_count  = css.scan(/font-family\s*:\s*["']?Lato/i).length
    font_family_serif_count = css.scan(/font-family\s*:[^;{}]*?(?:serif|Times\s+New\s+Roman)/i).length

    Rails.logger.info "[SP_FETCHER] CSS_RESPONSE " \
                      "target=#{target_url.inspect} " \
                      "base_origin=#{base_origin.inspect} " \
                      "cdn_prefix_used=#{@cdn_prefix_used.inspect} " \
                      "origin_status=#{response.code} " \
                      "origin_ct=#{response["content-type"].inspect} " \
                      "body_bytes=#{css.bytesize} " \
                      "font_refs_before=#{font_refs_before} " \
                      "font_refs_proxified=#{font_refs_proxified} " \
                      "font_refs_external=#{font_refs_external} " \
                      "font_family_lato_count=#{font_family_lato_count} " \
                      "font_family_serif_count=#{font_family_serif_count}"

    if font_refs_before > 0 && font_refs_proxified == 0
      Rails.logger.warn "[SP_FETCHER] CSS_FONT_REWRITE_ZERO " \
                        "target=#{target_url.inspect} " \
                        "font_refs_before=#{font_refs_before} " \
                        "base_origin=#{base_origin.inspect} " \
                        "cdn_prefix_used=#{@cdn_prefix_used.inspect} " \
                        "(font URLs not proxified — check base_origin vs actual font URL domain)"
    end

    Result.new(success: true, body: css, content_type: "text/css; charset=utf-8")
  end

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
    source_uri       = URI.parse(source_url)
    base_origin      = build_origin(source_uri)

    # Pre-scan __NEXT_DATA__ to extract the CDN assetPrefix before href rewriting.
    # When the prefix is an absolute CDN URL (e.g. https://static.falabella.io/renderer/abc),
    # any stylesheet or preload href that starts with it belongs to this site's asset pipeline
    # and must be proxified so the proxy can rewrite @font-face URLs inside those CSS files.
    # Without this, 3+ stylesheets load directly from the CDN, bypassing URL rewriting entirely.
    cdn_prefix_local = extract_next_cdn_prefix(html)
    Rails.logger.info "[SP_FETCHER] CDN_PREFIX_LOCAL_DETECT " \
                      "cdn_prefix=#{cdn_prefix_local.inspect}"

    # Collect and log stylesheet <link> tags BEFORE rewriting.
    before_stylesheets = []
    html.scan(/<link\b[^>]*>/i) do |tag|
      next unless tag.match?(/\brel\s*=\s*["']?stylesheet["']?/i)
      href_m = tag.match(/\bhref\s*=\s*(["'])(.*?)\1/i)
      href   = href_m ? href_m[2] : nil
      before_stylesheets << href
      Rails.logger.info "[SP_FETCHER] STYLESHEET_LINK original=#{href.inspect}"
    end
    Rails.logger.info "[SP_FETCHER] STYLESHEET_COUNT_BEFORE count=#{before_stylesheets.size}"

    # Log CSS preload/prefetch hints before rewriting so we can trace their original URLs.
    # These affect font loading timing and are a common source of post-hydration breakage.
    html.scan(/<link\b[^>]*>/i) do |tag|
      next unless tag.match?(/\brel\s*=\s*["']?(?:preload|prefetch)["']?/i)
      next unless tag.match?(/\bas\s*=\s*["']?style["']?/i)
      href_m       = tag.match(/\bhref\s*=\s*(["'])(.*?)\1/i)
      rel_m        = tag.match(/\brel\s*=\s*["']?(\w+)["']?/i)
      href         = href_m&.[](2)
      will_proxify = cdn_prefix_local && href.to_s.start_with?(cdn_prefix_local)
      Rails.logger.info "[SP_FETCHER] CSS_PRELOAD_LINK " \
                        "rel=#{rel_m&.[](1).inspect} " \
                        "href=#{href.inspect} " \
                        "will_proxify=#{will_proxify}"
    end

    # Remove <base> — the proxy URL must serve as the implicit base.
    html = html.gsub(/<base\b[^>]*>/i, "")

    # Rewrite URL-bearing attributes.
    # Covers standard attrs + lazy-load patterns + plugin data attributes (Real3D, etc.).
    # CDN asset-prefix URLs are also rewritten when a CDN prefix was detected above —
    # this ensures <link rel="stylesheet">, <link rel="preload" as="style">, and any other
    # CDN-hosted asset originally served via the CDN prefix routes through the proxy so
    # that font URL rewriting can happen inside those CSS files.
    html = html.gsub(/(\s(?:href|src|action|data-src|data-bg|poster|data-pdf|data-file|data-url|data-href|data-link)\s*=\s*)(["'])(.*?)\2/im) do
      url       = $3
      rewritten = if cdn_prefix_local && url.start_with?(cdn_prefix_local)
        # Absolute CDN URL belonging to this site's assetPrefix pipeline.
        # Strip the CDN base and replace with the proxy prefix so the request
        # routes through the proxy and font URLs inside CSS get rewritten.
        # Example: "https://static.falabella.io/renderer/abc/_next/static/css/x.css"
        #       →  "/proxy/org/slug/_next/static/css/x.css"
        "#{@proxy_prefix}#{url[cdn_prefix_local.length..]}"
      else
        rewrite_url(url, base_origin, source_uri)
      end
      "#{$1}#{$2}#{rewritten}#{$2}"
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
    html = html.gsub(/(<style\b[^>]*>)(.*?)(<\/style>)/im) do
      "#{$1}#{rewrite_css_urls($2, base_origin, source_uri)}#{$3}"
    end

    # <script id="__NEXT_DATA__"> — rewrite assetPrefix so the Next.js client
    # router configures webpack's public path to load CSS/JS chunks through the proxy.
    # This is the primary fix for dynamic lazy-loaded CSS modules (e.g. login forms,
    # modals) that Next.js inserts as <link> tags at runtime using the public path.
    html = html.gsub(/(<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>)(.*?)(<\/script>)/im) do
      tag_open, json_str, tag_close = $1, $2, $3
      begin
        data       = JSON.parse(json_str)
        old_prefix = data["assetPrefix"].to_s
        if old_prefix.start_with?("http://", "https://", "//")
          # Absolute CDN prefix — store the CDN base URL in cache so that sub-requests
          # for _next/static/* fetch from the CDN instead of the origin host.
          # Rewrite assetPrefix to the proxy prefix so Next.js routes dynamic CSS/JS
          # chunk requests through the proxy, enabling font URL rewriting inside those
          # chunks.  Without this, post-hydration CSS loads from the CDN without URL
          # rewriting, and @font-face src URLs are resolved against the CDN domain —
          # any CORS restriction on the CDN causes fonts to fall back to Times New Roman.
          cdn_base = old_prefix.start_with?("//") ? "https:#{old_prefix}" : old_prefix
          store_cdn_prefix(cdn_base.chomp("/"))
          data["assetPrefix"] = @proxy_prefix
          Rails.logger.info "[SP_FETCHER] NEXT_DATA_REWRITE_CDN " \
                            "old_cdn=#{cdn_base.inspect} " \
                            "new=#{@proxy_prefix.inspect} " \
                            "(CDN cached — _next/static chunks will route through proxy)"
        else
          # Empty, nil, or relative prefix — chunks resolve against current domain.
          # Rewrite so dynamic loading goes through the proxy instead of go.ubyca.com.
          data["assetPrefix"] = @proxy_prefix
          Rails.logger.info "[SP_FETCHER] NEXT_DATA_REWRITE " \
                            "old=#{old_prefix.inspect} " \
                            "new=#{@proxy_prefix.inspect}"
        end
        "#{tag_open}#{data.to_json}#{tag_close}"
      rescue JSON::ParseError => e
        Rails.logger.warn "[SP_FETCHER] NEXT_DATA_PARSE_FAIL #{e.message}"
        "#{tag_open}#{json_str}#{tag_close}"
      end
    end

    # All other <script>...</script> blocks — rewrite embedded same-origin URLs
    # and Next.js root-relative paths (webpack manifests, build manifests, configs).
    html = html.gsub(/(<script\b[^>]*>)(.*?)(<\/script>)/im) do
      # Skip __NEXT_DATA__ — already handled with JSON-aware rewrite above.
      next "#{$1}#{$2}#{$3}" if $1.match?(/\bid\s*=\s*["']__NEXT_DATA__["']/i)
      "#{$1}#{rewrite_inline_urls($2, base_origin)}#{$3}"
    end

    # Deduplicate and log stylesheet <link> tags AFTER rewriting.
    # Keeps the first occurrence of each href; removes exact duplicates.
    seen_hrefs = {}
    html = html.gsub(/<link\b[^>]*>/i) do |tag|
      next tag unless tag.match?(/\brel\s*=\s*["']?stylesheet["']?/i)
      href_m = tag.match(/\bhref\s*=\s*(["'])(.*?)\1/i)
      href   = href_m ? href_m[2] : nil
      next tag unless href  # no parseable href — leave the tag untouched

      if seen_hrefs[href]
        Rails.logger.warn "[SP_FETCHER] STYLESHEET_DUPLICATE href=#{href.inspect} (removed)"
        ""
      else
        seen_hrefs[href] = true
        Rails.logger.info "[SP_FETCHER] STYLESHEET_REWRITTEN to=#{href.inspect}"
        tag
      end
    end
    Rails.logger.info "[SP_FETCHER] STYLESHEET_COUNT_AFTER count=#{seen_hrefs.size}"

    # Diagnostic: count how many final stylesheet hrefs are still external (CDN/not proxified).
    # These CSS files load directly in the browser without going through the proxy.
    # Any @font-face rules inside them will have UNPROXIFIED font URLs.
    proxified_sheets  = seen_hrefs.keys.count { |h| h.to_s.start_with?(@proxy_prefix) }
    external_sheets   = seen_hrefs.keys.count { |h| h.to_s.start_with?("http://", "https://", "//") }
    Rails.logger.info "[SP_FETCHER] STYLESHEET_PROXY_SPLIT " \
                      "proxified=#{proxified_sheets} " \
                      "external_cdn=#{external_sheets} " \
                      "proxy_prefix=#{@proxy_prefix.inspect}"
    if external_sheets > 0
      Rails.logger.warn "[SP_FETCHER] STYLESHEET_CDN_BYPASS " \
                        "count=#{external_sheets} " \
                        "(these CSS files load from CDN directly — " \
                        "their @font-face URLs will NOT be rewritten through proxy)"
    end

    html
  end

  def rewrite_url(url, base_origin, source_uri)
    url = url.to_s.strip
    return url if url.empty?
    return url if url.start_with?("data:", "mailto:", "tel:", "javascript:", "#", "blob:")

    if url.start_with?("//")
      # Protocol-relative — treat as HTTPS for origin check.
      u = URI.parse("https:#{url}") rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxify_uri(u) : url

    elsif url.start_with?("https://", "http://")
      u = URI.parse(url) rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxify_uri(u) : url

    elsif url.start_with?("/")
      "#{@proxy_prefix}#{url}"

    else
      # Relative URL (./path, ../path, or bare relative like "images/logo.png").
      # Resolve against the source page URL so the browser doesn't have to —
      # this avoids path-prefix ambiguity when the proxy root has no trailing slash.
      u = URI.join(source_uri, url) rescue nil
      return url unless u
      same_origin?(u, base_origin) ? proxify_uri(u) : u.to_s
    end
  end

  def rewrite_srcset(srcset, base_origin, source_uri)
    srcset.split(",").map do |entry|
      parts    = entry.strip.split(/\s+/, 2)
      parts[0] = rewrite_url(parts[0].to_s, base_origin, source_uri) if parts[0]
      parts.join(" ")
    end.join(", ")
  end

  # ── CSS rewriting ─────────────────────────────────────────────────────────

  # Full CSS rewrite: url() references + @import directives.
  # Called for .css files served through the proxy (serve_css).
  # Also called for inline <style> blocks via rewrite_html.
  def rewrite_css(css, base_origin, source_uri)
    css = rewrite_css_urls(css, base_origin, source_uri)
    # @import "url"  or  @import 'url'  (without url() wrapper)
    css.gsub(/@import\s*(["'])(.*?)\1/m) do
      "@import #{$1}#{rewrite_url($2, base_origin, source_uri)}#{$1}"
    end
  end

  # Rewrite url(...) occurrences: quoted, single-quoted, or bare.
  # Used by serve_css, and by rewrite_html for <style> blocks and style= attrs.
  def rewrite_css_urls(css, base_origin, source_uri)
    css.gsub(/url\(\s*(["']?)(.*?)\1\s*\)/m) do
      quote = $1
      url   = $2.strip
      "url(#{quote}#{rewrite_url(url, base_origin, source_uri)}#{quote})"
    end
  end

  # Rewrite absolute same-origin URLs embedded in inline script blocks.
  # Does NOT rewrite root-relative paths: those are handled either via __NEXT_DATA__
  # assetPrefix (for Next.js) or via attribute-level rewriting (href=/src=).
  def rewrite_inline_urls(text, base_origin)
    pattern = /#{Regexp.escape(base_origin)}(\/[^\s"'`<>\\),;]*)/i
    text.gsub(pattern) { "#{@proxy_prefix}#{$1}" }
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

  # Returns the fallback MIME type for a URL whose path has a known asset extension,
  # or nil if the URL is not a recognized asset (e.g. an HTML page path).
  def asset_mime_for_url(url)
    path = URI.parse(url).path rescue url
    ext  = File.extname(path.split("?").first).downcase
    ASSET_EXTENSIONS[ext]
  rescue
    nil
  end

  # ── Server-side asset cache ────────────────────────────────────────────────

  def cache_key(target_url)
    # Scoped by proxy so two proxies pointing to the same origin don't share entries
    # (their @proxy_prefix rewrites would produce different body content).
    "smart_proxy/v1/#{@smart_proxy.id}/#{Digest::SHA256.hexdigest(target_url)}"
  end

  def load_from_cache(target_url)
    key = cache_key(target_url)
    Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_READ key=#{key}"
    entry = Rails.cache.read(key)
    if entry
      Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_READ_HIT key=#{key} " \
                        "entry_keys=#{entry.keys.inspect} " \
                        "body_bytes=#{entry[:body].to_s.bytesize} " \
                        "ct=#{entry[:content_type].inspect}"
      Result.new(success: true, body: entry[:body], content_type: entry[:content_type])
    else
      Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_READ_EMPTY key=#{key}"
      nil
    end
  rescue => e
    Rails.logger.warn "[SP_FETCHER] SMART_PROXY_CACHE_READ_ERROR key=#{key} error=#{e.message}"
    nil
  end

  def store_in_cache(target_url, result)
    key = cache_key(target_url)
    Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_STORE key=#{key} " \
                      "body_bytes=#{result.body.to_s.bytesize} " \
                      "ct=#{result.content_type.inspect} " \
                      "ttl=#{CACHE_TTL}"
    ok = Rails.cache.write(
      key,
      { body: result.body, content_type: result.content_type },
      expires_in: CACHE_TTL
    )
    if ok
      Rails.logger.info "[SP_FETCHER] SMART_PROXY_CACHE_STORE_OK key=#{key}"
    else
      Rails.logger.warn "[SP_FETCHER] SMART_PROXY_CACHE_STORE_FAILED key=#{key} " \
                        "(write returned false — NullStore or size limit?)"
    end
  rescue => e
    Rails.logger.warn "[SP_FETCHER] SMART_PROXY_CACHE_STORE_ERROR key=#{key} error=#{e.message}"
  end

  def build_origin(uri)
    o = "#{uri.scheme}://#{uri.host}"
    o += ":#{uri.port}" unless default_port?(uri)
    o
  end

  def proxy_path(uri)
    "#{@proxy_prefix}#{uri.path}#{query_string(uri)}"
  end

  # Like proxy_path, but strips the CDN build prefix when @cdn_prefix_used is set.
  # CDN-hosted CSS files contain font URLs whose URI path starts with the CDN build
  # prefix (e.g. "/renderer/8a466bf2/_next/static/media/font.woff2"). proxy_path alone
  # produces "/proxy/org/slug/renderer/8a466bf2/_next/static/media/font.woff2", which
  # does NOT match the "_next/static/" branch in build_target_url → falls back to
  # origin → 404 → Times New Roman.  Stripping the CDN build prefix here produces
  # "/proxy/org/slug/_next/static/media/font.woff2", which correctly hits the CDN
  # branch and fetches the font from the CDN.
  def proxify_uri(u)
    abs = u.to_s
    if @cdn_prefix_used && abs.start_with?("#{@cdn_prefix_used}/")
      "#{@proxy_prefix}#{abs[@cdn_prefix_used.length..]}"
    else
      proxy_path(u)
    end
  end

  # Encode characters that are valid in decoded form (e.g. from Rails params) but
  # illegal in a URI string. Bracket characters appear in Next.js dynamic-route chunk
  # names (e.g. _next/static/chunks/pages/[slug]-abc123.js) and cause URI.parse to
  # raise URI::InvalidURIError, which fetch_with_redirects silences as nil → 502.
  def url_safe_path(path)
    path.gsub(/[\[\]{}|\\^`]/) { |c| "%" + c.ord.to_s(16).upcase }
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

    if @path.blank?
      # Root request — load the configured destination page exactly as stored.
      Rails.logger.info "[SP_FETCHER] URL_RESOLVE input=(root) resolved=#{base.inspect}"
      return base
    end

    # For Next.js static/data assets, use the cached CDN base URL if available.
    # Sites with an absolute CDN assetPrefix (e.g. static.falabella.io) store their
    # _next/static/* and _next/data/* files on the CDN, not on the origin host.
    # We rewrite assetPrefix to the proxy prefix so dynamic chunks go through the
    # proxy (enabling font URL rewriting), but the actual files must be fetched from
    # the CDN.  Without this, origin returns 404/HTML → empty CSS → font fallback.
    if (@path.start_with?("_next/static/") || @path.start_with?("_next/data/")) &&
       (cdn = load_cdn_prefix)
      @cdn_prefix_used = cdn
      target = "#{cdn}/#{url_safe_path(@path)}"
      Rails.logger.info "[SP_FETCHER] URL_RESOLVE_CDN input=#{@path.inspect} " \
                        "cdn=#{cdn.inspect} " \
                        "resolved=#{target.inspect}"
      return target
    end

    # Warn when a _next/ path falls through to origin — this almost certainly
    # means the CDN prefix was never cached (NullStore, cross-process miss, or
    # the HTML was not processed through this fetcher first).
    if @path.start_with?("_next/static/") || @path.start_with?("_next/data/")
      Rails.logger.warn "[SP_FETCHER] NEXT_PATH_CDN_MISS " \
                        "path=#{@path.inspect} " \
                        "proxy_id=#{@smart_proxy.id} " \
                        "(falling back to origin — font CSS may 404 → Times New Roman)"
    end

    # Sub-resource paths are ALWAYS resolved against the origin root (scheme://host),
    # never against destination_url's full path. proxy_path() stores the absolute path
    # component of the original URL (e.g. "/css/file.css" → "css/file.css" in @path),
    # so prepending destination_url's own path would double-prefix it:
    #   destination "https://example.com/subdir" + path "css/file.css"
    #   → "https://example.com/subdir/css/file.css"  ← WRONG
    #   origin_root "https://example.com" + path "css/file.css"
    #   → "https://example.com/css/file.css"          ← CORRECT
    origin_root = build_origin(URI.parse(base))
    target      = "#{origin_root}/#{url_safe_path(@path)}"
    Rails.logger.info "[SP_FETCHER] URL_RESOLVE input=#{@path.inspect} " \
                      "destination=#{base.inspect} " \
                      "origin=#{origin_root.inspect} " \
                      "resolved=#{target.inspect}"
    target
  rescue => e
    Rails.logger.error "[SP_FETCHER] URL_RESOLVE_ERROR path=#{@path.inspect} error=#{e.message}"
    nil
  end

  # ── CDN prefix helpers ────────────────────────────────────────────────────

  # Read-only scan of raw HTML to extract an absolute assetPrefix from __NEXT_DATA__.
  # Returns the CDN base URL (no trailing slash), or nil if none / relative prefix.
  # Called at the start of rewrite_html so CDN stylesheet hrefs can be proxified
  # in the same attribute-rewriting pass, before __NEXT_DATA__ itself is processed.
  def extract_next_cdn_prefix(html)
    m = html.match(
      /<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(.*?)<\/script>/im
    )
    return nil unless m
    prefix = JSON.parse(m[1])["assetPrefix"].to_s
    return nil unless prefix.start_with?("http://", "https://", "//")
    (prefix.start_with?("//") ? "https:#{prefix}" : prefix).chomp("/")
  rescue
    nil
  end

  # ── CDN prefix cache ──────────────────────────────────────────────────────

  # Per-proxy cache key for the CDN base URL discovered from __NEXT_DATA__.assetPrefix.
  def cdn_prefix_cache_key
    "smart_proxy/cdn_prefix/#{@smart_proxy.id}"
  end

  # Persist the CDN base URL so subsequent asset sub-requests can use it.
  def store_cdn_prefix(cdn_base)
    ok = Rails.cache.write(cdn_prefix_cache_key, cdn_base, expires_in: 2.hours)
    if ok
      Rails.logger.info "[SP_FETCHER] CDN_PREFIX_STORED " \
                        "cdn=#{cdn_base.inspect} " \
                        "key=#{cdn_prefix_cache_key.inspect} " \
                        "store_class=#{Rails.cache.class.name}"
    else
      Rails.logger.warn "[SP_FETCHER] CDN_PREFIX_STORE_NOOP " \
                        "cdn=#{cdn_base.inspect} " \
                        "key=#{cdn_prefix_cache_key.inspect} " \
                        "store_class=#{Rails.cache.class.name} " \
                        "(write returned false — NullStore or cache full? _next/ paths will fall back to origin)"
    end
  rescue => e
    Rails.logger.warn "[SP_FETCHER] CDN_PREFIX_STORE_FAILED #{e.message}"
  end

  # Read the CDN base URL from cache. Returns nil on miss or error.
  def load_cdn_prefix
    key = cdn_prefix_cache_key
    val = Rails.cache.read(key)
    if val
      Rails.logger.info "[SP_FETCHER] CDN_PREFIX_HIT key=#{key.inspect} cdn=#{val.inspect}"
    else
      Rails.logger.warn "[SP_FETCHER] CDN_PREFIX_MISS key=#{key.inspect} " \
                        "store_class=#{Rails.cache.class.name} " \
                        "(no CDN URL cached — _next/ paths will resolve against origin)"
    end
    val
  rescue => e
    Rails.logger.warn "[SP_FETCHER] CDN_PREFIX_LOAD_FAILED #{e.message}"
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

    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError => e
      Rails.logger.warn "[SP_FETCHER] URI_PARSE_FAILED url=#{url[0, 200].inspect} error=#{e.message}"
      nil
    end
    return nil unless uri && secure_uri?(uri)

    response = http_get(uri)
    return nil unless response

    if response.is_a?(Net::HTTPRedirection)
      location = response["location"].to_s.strip
      Rails.logger.info "[SP_FETCHER] REDIRECT #{response.code} #{url.inspect} → #{location.inspect} (hop #{count + 1})"
      return nil if location.empty?
      next_url = location.start_with?("http") ? location : URI.join(url, location).to_s
      fetch_with_redirects(next_url, count + 1)
    else
      response
    end
  rescue URI::InvalidURIError => e
    Rails.logger.warn "[SP_FETCHER] Invalid URI: #{e.message}"
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
    org          = @smart_proxy.organization
    proxy_id     = @smart_proxy.id
    org_slug     = org.slug
    slug         = @smart_proxy.slug
    api_base     = @api_base
    origin_host  = URI.parse(@smart_proxy.destination_url).host.to_s rescue ""
    proxy_prefix = @proxy_prefix

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

        var _OH = #{origin_host.to_json};
        var _PP = #{proxy_prefix.to_json};
        function proxify(href) {
          if (!href) return null;
          try {
            var u = new URL(href, location.href);
            if (u.hostname !== _OH) return null;
            return _PP + u.pathname + u.search + u.hash;
          } catch (_e) { return null; }
        }

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
          var el = t.closest ? t.closest('a') : (function(){
            var n = t; while (n && n.tagName !== 'A') n = n.parentElement; return n;
          })();
          if (!el) return;
          var raw = el.href || '';
          if (!raw || raw === '#' || /^(javascript|mailto|tel|blob):/.test(raw)) return;
          var proxied = proxify(raw);
          if (!proxied) return;
          e.preventDefault();
          e.stopPropagation();
          if (el.getAttribute('target') === '_blank') {
            window.open(proxied, '_blank', 'noopener,noreferrer');
          } else {
            location.href = proxied;
          }
        }, true);

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
