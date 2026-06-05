class SmartLink < ApplicationRecord
  SCOPE_TYPES       = %w[project geo_points].freeze
  DESTINATION_TYPES = %w[external_url].freeze
  STATUSES          = %w[active paused archived].freeze

  VALID_URL_REGEX     = /\Ahttps?:\/\/.+/i.freeze
  DESTINATION_URL_MAX = 2048
  GO_BASE_URL         = "https://go.ubyca.com".freeze
  private_constant :VALID_URL_REGEX, :DESTINATION_URL_MAX, :GO_BASE_URL

  belongs_to :user
  belongs_to :organization
  belongs_to :project, class_name: "GeoProject", foreign_key: :project_id
  has_many   :smart_link_geo_points, dependent: :destroy
  has_many   :geo_points, through: :smart_link_geo_points

  before_validation :generate_slug_from_name

  validates :name,             presence: true, length: { maximum: 255 }
  validates :slug,             presence: true, uniqueness: { scope: :organization_id },
                               format: { with: /\A[a-z0-9\-]+\z/,
                                         message: "solo puede contener letras minúsculas, números y guiones" }
  validates :scope_type,       inclusion: { in: SCOPE_TYPES }
  validates :destination_type, inclusion: { in: DESTINATION_TYPES }
  validates :status,           inclusion: { in: STATUSES }
  validate  :destination_url_required_and_valid
  validate  :geo_points_present_when_required

  def as_api_json
    {
      id:               id,
      name:             name,
      slug:             slug,
      organizationSlug: organization.slug,
      publicUrl:        public_url,
      scopeType:        scope_type,
      destinationType:  destination_type,
      destinationUrl:   destination_url,
      status:           status,
      projectId:        project_id,
      geoPointIds:      smart_link_geo_points.map(&:geo_point_id),
      uiConfig:         ui_config,
      createdAt:        created_at.iso8601(3),
      updatedAt:        updated_at.iso8601(3)
    }
  end

  def as_public_json
    {
      name:             name,
      slug:             slug,
      organizationSlug: organization.slug,
      status:           status,
      projectId:        project_id,
      scopeType:        scope_type,
      geoPointIds:      smart_link_geo_points.map(&:geo_point_id)
    }
  end

  def public_url
    "#{GO_BASE_URL}/#{organization.slug}/#{slug}"
  end

  private

  def generate_slug_from_name
    self.slug = slug.present? ? slug.to_s.parameterize : name.to_s.parameterize
  end

  def destination_url_required_and_valid
    return unless destination_type == "external_url"
    if destination_url.blank?
      errors.add(:destination_url, "es obligatorio para destination_type external_url")
    elsif destination_url.length > DESTINATION_URL_MAX
      errors.add(:destination_url, "no puede superar #{DESTINATION_URL_MAX} caracteres")
    elsif !VALID_URL_REGEX.match?(destination_url)
      errors.add(:destination_url, "debe comenzar con http:// o https://")
    end
  end

  def geo_points_present_when_required
    return unless scope_type == "geo_points"
    return if smart_link_geo_points.present?
    errors.add(:base, "Se requiere al menos un punto cuando scope_type es geo_points")
  end
end
