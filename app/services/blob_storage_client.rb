require "net/http"
require "uri"
require "json"

# Client for Vercel Blob Storage.
#
# Detection:
#   URLs are considered internal when their hostname matches either:
#   - the BLOB_HOSTNAME env var (exact match, e.g. "abc123.public.blob.vercel-storage.com")
#   - or the generic *.blob.vercel-storage.com pattern when BLOB_HOSTNAME is unset.
#
# Deletion API:
#   DELETE https://api.vercel.com/v1/blob
#   Authorization: Bearer <BLOB_READ_WRITE_TOKEN>
#   Content-Type: application/json
#   Body: { "urls": ["<blob_url>"] }
#
# Required env var: BLOB_READ_WRITE_TOKEN
# Optional env var: BLOB_HOSTNAME  — pin to a specific store hostname
class BlobStorageClient
  VERCEL_BLOB_PATTERN = /\.blob\.vercel-storage\.com\z/i.freeze
  DELETE_ENDPOINT     = "https://api.vercel.com/v1/blob/delete"
  TIMEOUT_SECONDS     = 10

  # ── URL detection ──────────────────────────────────────────────────────────

  # Returns true when +url+ looks like an internal Blob Storage URL.
  # Base64 strings and external URLs (Google, YouTube, etc.) always return false.
  def self.internal_url?(url)
    return false unless url.is_a?(String) && url.start_with?("https://")
    host = URI.parse(url).host.to_s
    return false if host.empty?

    configured_host = ENV["BLOB_HOSTNAME"].presence
    configured_host ? host == configured_host : VERCEL_BLOB_PATTERN.match?(host)
  rescue URI::InvalidURIError
    false
  end

  # Walks +obj+ (Hash / Array / String) recursively and returns every unique
  # internal blob URL found in any string value.
  def self.extract_blob_urls(obj)
    urls = []
    case obj
    when Hash  then obj.each_value { |v| urls.concat(extract_blob_urls(v)) }
    when Array then obj.each       { |v| urls.concat(extract_blob_urls(v)) }
    when String then urls << obj if internal_url?(obj)
    end
    urls.uniq
  end

  # ── Ownership guard ────────────────────────────────────────────────────────

  # Returns true only when +url+ is NOT referenced by any real GeoProject or
  # GeoPoint. Conservative: if the URL appears anywhere in production data,
  # we refuse to delete it even if it's also in a temporary preview.
  def self.exclusive_to_temporary_previews?(url)
    return false if GeoProject.where(cover_image: url).exists?
    return false if GeoPoint.where(image: url).exists?

    # Broad JSONB text scan — acceptable for a background cleanup task.
    escaped = ActiveRecord::Base.sanitize_sql_like(url)
    return false if GeoPoint.where("content_data::text LIKE ?", "%#{escaped}%").exists?

    true
  end

  # ── Deletion ───────────────────────────────────────────────────────────────

  # Deletes +url+ from Vercel Blob via the REST API.
  # Raises if the token is missing or the API returns a non-2xx status.
  def self.delete!(url)
    token = ENV["BLOB_READ_WRITE_TOKEN"].presence
    raise "BLOB_READ_WRITE_TOKEN is not configured" unless token

    uri = URI(DELETE_ENDPOINT)
    req = Net::HTTP::Delete.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Content-Type"]  = "application/json"
    req.body = JSON.dump({ urls: [ url ] })

    resp = Net::HTTP.start(
      uri.host, uri.port,
      use_ssl:      true,
      open_timeout: TIMEOUT_SECONDS,
      read_timeout: TIMEOUT_SECONDS
    ) { |http| http.request(req) }

    return true if resp.is_a?(Net::HTTPSuccess)

    raise "Vercel Blob API #{resp.code}: #{resp.body.to_s.slice(0, 200)}"
  end
end
