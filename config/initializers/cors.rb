allowed = [
  "http://localhost:5173",
  "http://localhost:5174",
  "https://geo-ar-chi.vercel.app"
].freeze

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed)

    resource "*",
             headers: :any,
             methods: %i[get post put patch delete options head]
  end
end
