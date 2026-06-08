class SmartProxy < ApplicationRecord
  PROXY_STATUSES = %w[unknown supported partial failed].freeze

  GO_BASE_URL = "https://go.ubyca.com".freeze

  VALID_URL_REGEX         = /\Ahttps?:\/\/.+/i.freeze
  DESTINATION_URL_MAX     = 2048
  BLOCKED_HOSTS           = %w[localhost 127.0.0.1 ::1 0.0.0.0].freeze
  PRIVATE_IP_PATTERNS     = [
    /\A10\.\d+\.\d+\.\d+\z/,
    /\A172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\z/,
    /\A192\.168\.\d+\.\d+\z/,
    /\A169\.254\.\d+\.\d+\z/,
    /\Afc[0-9a-f]{2}:/i,
    /\Afd[0-9a-f]{2}:/i
  ].freeze
  private_constant :VALID_URL_REGEX, :DESTINATION_URL_MAX, :GO_BASE_URL,
                   :BLOCKED_HOSTS, :PRIVATE_IP_PATTERNS

  belongs_to :organization
  belongs_to :user
  has_many   :smart_proxy_live_visits, dependent: :destroy

  before_validation :generate_slug_from_name

  validates :name,            presence: true, length: { maximum: 255 }
  validates :proxy_status,    inclusion: { in: PROXY_STATUSES }
  validates :slug,            presence: true,
                              uniqueness: { scope: :organization_id },
                              format: { with: /\A[a-z0-9\-]+\z/,
                                        message: "solo puede contener letras minúsculas, números y guiones" }
  validates :destination_url, presence: true
  validate  :destination_url_valid

  def as_api_json
    {
      id:             id,
      name:           name,
      slug:           slug,
      organizationId: organization_id,
      organizationSlug: organization.slug,
      publicUrl:      public_url,
      destinationUrl: destination_url,
      proxyStatus:    proxy_status,
      active:         active,
      customDomain:   custom_domain,
      domainStatus:   domain_status,
      sslStatus:      ssl_status,
      createdAt:      created_at.iso8601(3),
      updatedAt:      updated_at.iso8601(3)
    }
  end

  # Proxy prefix used to rewrite URLs in the proxied HTML.
  # Uses the request host so future custom domains work without code changes.
  def proxy_path_prefix
    "/proxy/#{organization.slug}/#{slug}"
  end

  # Public URL for display (uses go.ubyca.com as default host).
  # If a verified custom_domain exists, use that instead.
  def public_url(request_host = nil)
    host = (domain_status == "active" && custom_domain.present?) ? custom_domain : (request_host || GO_BASE_URL.sub(/\Ahttps?:\/\//, ""))
    base = custom_domain.present? && domain_status == "active" ? "https://#{host}" : GO_BASE_URL
    "#{base}/proxy/#{organization.slug}/#{slug}"
  end

  def self.resolve(host:, org_slug:, proxy_slug:)
    # If the host is a known custom domain, look it up that way.
    by_domain = where(custom_domain: host, domain_status: "active", active: true)
                  .joins(:organization)
                  .where(organizations: { slug: org_slug })
                  .find_by(slug: proxy_slug)
    return by_domain if by_domain

    # Standard resolution: org slug + proxy slug.
    org = Organization.find_by(slug: org_slug)
    return nil unless org
    org.smart_proxies.find_by(slug: proxy_slug, active: true)
  end

  private

  def generate_slug_from_name
    self.slug = slug.present? ? slug.to_s.parameterize : name.to_s.parameterize
  end

  def destination_url_valid
    return if destination_url.blank?

    if destination_url.length > DESTINATION_URL_MAX
      errors.add(:destination_url, "no puede superar #{DESTINATION_URL_MAX} caracteres")
      return
    end

    unless VALID_URL_REGEX.match?(destination_url)
      errors.add(:destination_url, "debe comenzar con http:// o https://")
      return
    end

    begin
      uri = URI.parse(destination_url)
      host = uri.host.to_s.downcase
      if BLOCKED_HOSTS.include?(host)
        errors.add(:destination_url, "no puede apuntar a una dirección local o privada")
        return
      end
      if PRIVATE_IP_PATTERNS.any? { |p| p.match?(host) }
        errors.add(:destination_url, "no puede apuntar a una dirección IP privada")
      end
    rescue URI::InvalidURIError
      errors.add(:destination_url, "no es una URL válida")
    end
  end
end
