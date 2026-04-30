Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").map(&:strip)

    resource "/api/*",
             headers: :any,
             methods: %i[get post put patch delete options head],
             expose: ["Content-Type"]
  end
end
