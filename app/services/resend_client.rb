require "net/http"
require "json"

class ResendClient
  API_URL = "https://api.resend.com/emails"

  def self.deliver(from:, to:, subject:, html:)
    uri     = URI(API_URL)
    http    = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{ENV['RESEND_API_KEY']}"
    request["Content-Type"]  = "application/json"
    request.body = { from: from, to: Array(to), subject: subject, html: html }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error "[ResendClient] Error #{response.code}: #{response.body}"
    end
  end
end
