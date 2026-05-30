class Rack::Attack
  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Normalizes the client IP from standard headers or the direct socket address.
  # Trusts Railway/Heroku proxy headers for production; falls back to REMOTE_ADDR.
  def self.client_ip(req)
    req.env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip ||
      req.env["HTTP_CF_CONNECTING_IP"] ||
      req.ip
  end

  # ── Throttle rules ───────────────────────────────────────────────────────────

  # POST /api/auth/login — 5 attempts per minute per IP
  throttle("auth/login", limit: 5, period: 1.minute) do |req|
    client_ip(req) if req.post? && req.path == "/api/auth/login"
  end

  # POST /api/auth/register — 3 per minute per IP
  throttle("auth/register", limit: 3, period: 1.minute) do |req|
    client_ip(req) if req.post? && req.path == "/api/auth/register"
  end

  # POST /api/auth/forgot_password — 3 per 10 minutes per IP
  throttle("auth/forgot_password", limit: 3, period: 10.minutes) do |req|
    client_ip(req) if req.post? && req.path == "/api/auth/forgot_password"
  end

  # POST /api/analytics_events — 60 per minute per IP (public, high-volume)
  throttle("analytics/events", limit: 60, period: 1.minute) do |req|
    client_ip(req) if req.post? && req.path == "/api/analytics_events"
  end

  # POST /api/public/geo_points/:id/live_visit — 30 per minute per IP
  throttle("public/live_visit", limit: 30, period: 1.minute) do |req|
    client_ip(req) if req.post? && req.path.match?(%r{\A/api/public/geo_points/[^/]+/live_visit\z})
  end

  # POST /api/invitations — 10 per minute per IP
  throttle("invitations/create", limit: 10, period: 1.minute) do |req|
    client_ip(req) if req.post? && req.path == "/api/invitations"
  end

  # ── Throttle response ─────────────────────────────────────────────────────────
  # Returns JSON instead of the default plain-text body so the frontend can
  # parse the error message consistently.
  self.throttled_responder = lambda do |env|
    retry_after = env["rack.attack.match_data"]&.dig(:period)
    headers = {
      "Content-Type"  => "application/json",
      "Retry-After"   => retry_after.to_s
    }
    body = JSON.generate({ error: "Demasiadas solicitudes. Intenta nuevamente más tarde." })
    [ 429, headers, [ body ] ]
  end
end
