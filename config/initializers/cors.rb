# Authenticated app + dev origins.
# Cookies/session are allowed; used by studio and local development.
STUDIO_ORIGINS = [
  "https://studio.ubyca.com",
  "https://geo-ar-chi.vercel.app",
  "http://localhost:5173",
  "http://localhost:5174",
].freeze

# Public landing page origins.
# Credential-free; only exposes the public endpoints the marketing site needs.
LANDING_ORIGINS = [
  "https://ubyca.com",
  "https://www.ubyca.com",
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
end
