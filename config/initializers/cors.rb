# Authenticated app + dev origins.
# Cookies/session are allowed; used by studio and local development.
STUDIO_ORIGINS = [
  "https://studio.ubyca.com",
  "https://geo-ar-chi.vercel.app",
  "http://localhost:5173",
  "http://localhost:5174"
].freeze

# Public landing page origins.
# Credential-free; only exposes the public endpoints the marketing site needs.
LANDING_ORIGINS = [
  "https://ubyca.com",
  "https://www.ubyca.com"
].freeze

# Smart Proxy domain — serves proxied pages and injected validation scripts.
# Credential-free; exposes /api/public/* for geo_project/geo_point lookups and
# live_visit heartbeats triggered by the injected browser script.
GO_ORIGINS = [
  "https://go.ubyca.com"
].freeze

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  # Studio / dev — full access, credentials (session cookies) enabled.
  allow do
    origins(*STUDIO_ORIGINS)
    resource "*",
             headers:     :any,
             methods:     %i[get post put patch delete options head],
             credentials: true
  end

  # Landing page — public, credential-free access to the plans listing only.
  # ubyca.com/precios fetches this with credentials: 'omit'; no session needed.
  allow do
    origins(*LANDING_ORIGINS)
    resource "/api/plans",
             headers:     :any,
             methods:     %i[get options head],
             credentials: false
  end

  # Smart Proxy domain — public, credential-free.
  # Covers /api/public/*: geo_project show, geo_points index + access,
  # live_visit heartbeat, and Smart Proxy analytics events.
  allow do
    origins(*GO_ORIGINS)
    resource "/api/public/*",
             headers:     :any,
             methods:     %i[get post options head],
             credentials: false
  end

  # Smart Proxy analytics events — also reachable from any origin because the
  # injected script runs inside proxied pages that may be on custom domains.
  # This is the narrowest wildcard we can use while supporting custom domains.
  allow do
    origins "*"
    resource "/api/public/smart_proxy_events",
             headers:     :any,
             methods:     %i[post options],
             credentials: false
  end
end

# Temporary diagnostic middleware — logs what rack-cors decided for landing origins.
# Remove once CORS from ubyca.com is confirmed working in Railway logs.
Rails.application.config.middleware.use(Class.new do
  def initialize(app)
    @app = app
  end

  def call(env)
    origin = env["HTTP_ORIGIN"].to_s
    path   = env["PATH_INFO"].to_s
    is_landing = origin.match?(/\Ahttps?:\/\/(www\.)?ubyca\.com\z/) &&
                 !origin.include?("studio")

    Rails.logger.info "[CORS_MW] in  origin=#{origin.inspect} path=#{path}" if is_landing

    status, headers, body = @app.call(env)

    if is_landing
      acao = headers["Access-Control-Allow-Origin"].inspect
      Rails.logger.info "[CORS_MW] out origin=#{origin.inspect} path=#{path} acao=#{acao} status=#{status}"
    end

    [ status, headers, body ]
  end
end)
