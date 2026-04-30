CORS_DEFAULT_ORIGINS = %w[
  http://localhost:5173
  http://localhost:5174
  https://geo-ar-henna.vercel.app
].freeze

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    allowed = ENV["ALLOWED_ORIGINS"]
               &.split(",")
               &.map(&:strip)
               &.reject(&:empty?) || CORS_DEFAULT_ORIGINS

    origins allowed

    resource "/api/*",
             headers: :any,
             methods: %i[get post put patch delete options head],
             expose: ["Content-Type"]
  end
end
