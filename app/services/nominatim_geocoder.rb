require "net/http"
require "json"

# Reverse-geocodes a lat/lng using Nominatim (OpenStreetMap).
# Returns { country:, city:, commune: } or nil on any error.
# Never raises — callers must handle nil gracefully.
class NominatimGeocoder
  BASE_URL      = "https://nominatim.openstreetmap.org/reverse"
  OPEN_TIMEOUT  = 3
  READ_TIMEOUT  = 5

  def self.reverse(latitude, longitude)
    uri       = URI(BASE_URL)
    uri.query = URI.encode_www_form(
      lat:            latitude,
      lon:            longitude,
      format:         "json",
      zoom:           10,
      addressdetails: 1,
    )

    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Get.new(uri)
    req["User-Agent"]      = "geo-ar-api/1.0"
    req["Accept-Language"] = "es"

    res = http.request(req)
    return nil unless res.is_a?(Net::HTTPSuccess)

    data    = JSON.parse(res.body)
    address = data["address"] || {}

    {
      country: address["country"].presence,
      city:    (address["city"] || address["town"] || address["village"] || address["county"]).presence,
      commune: (address["suburb"] || address["neighbourhood"] || address["quarter"] || address["municipality"]).presence
    }
  rescue => e
    Rails.logger.warn "[NominatimGeocoder] #{e.class}: #{e.message}"
    nil
  end
end
