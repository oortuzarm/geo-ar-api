class GeoPoint < ApplicationRecord
  CONTENT_TYPES    = %w[url video audio file].freeze
  ACTIVATION_MODES = %w[radius polygon].freeze

  belongs_to :geo_project, inverse_of: :geo_points
  has_many   :analytics_events,      dependent: :destroy
  has_many   :geo_point_live_visits, dependent: :destroy

  validates :latitude,           presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude,          presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :activation_radius,  numericality: { greater_than: 0, only_integer: true }
  validates :order,              numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :content_type,    inclusion: { in: CONTENT_TYPES }
  validates :activation_mode, inclusion: { in: ACTIVATION_MODES }
  validates :activation_polygon, presence: true, if: -> { activation_mode == "polygon" }
  validate  :activation_polygon_is_valid_geojson,
            if: -> { activation_mode == "polygon" && activation_polygon.present? }

  validates :dwell_time_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate  :dwell_time_required_when_enabled
  validate  :content_data_matches_schema

  validates :name,         length: { maximum: 255  }, allow_nil: true
  validates :description,  length: { maximum: 2000 }, allow_nil: true
  validates :instructions, length: { maximum: 500  }, allow_nil: true
  validates :button_text,  length: { maximum: 100  }, allow_nil: true
  validates :lookiar_url,  length: { maximum: 2048 }, allow_nil: true

  # Public variant: excludes content fields so the destination is never
  # exposed in the HTML payload. Content is returned only after server-side
  # validation via POST .../geo_points/:id/access.
  # contentType IS included so the frontend can show the right icon/button.
  def as_public_api_json
    as_api_json.except(:lookiarUrl, :contentData)
  end

  def as_api_json
    {
      id:                 id,
      geoProjectId:       geo_project_id,
      name:               name,
      lookiarUrl:         lookiar_url,
      contentType:        content_type,
      contentData:        content_data,
      latitude:           latitude,
      longitude:          longitude,
      activationRadius:   activation_radius,
      image:              image,
      images:             camelize_images(images),
      description:        description,
      instructions:       instructions,
      buttonText:         button_text,
      active:             active,
      order:              order,
      availability:        camelize_availability(availability),
      requiresDwellTime:   requires_dwell_time,
      dwellTimeSeconds:    dwell_time_seconds,
      activationMode:      activation_mode,
      activationPolygon:   activation_polygon,
      createdAt:           created_at.iso8601(3)
    }
  end

  # Normalize incoming images array before storing in JSONB.
  # Accepts ActionController::Parameters arrays and plain arrays.
  def images=(val)
    super(self.class.normalize_images(val))
  end

  # Class-level so geo_projects_controller#sync can call it during upsert_all,
  # which bypasses instance callbacks.
  def self.normalize_images(val)
    return [] unless val.is_a?(Array)
    val.map.with_index do |img, idx|
      h = img.respond_to?(:to_unsafe_h) ? img.to_unsafe_h.to_h.stringify_keys : img.to_h.stringify_keys
      {
        "id"       => h["id"].to_s,
        "url"      => h["url"].to_s,
        "is_cover" => h["is_cover"] == true || h["isCover"] == true || h["is_cover"] == "true",
        "position" => (h["position"] || idx).to_i
      }
    end
  end

  private

  # ── content_data schema validation ────────────────────────────────────────
  #
  # Only runs when content_data is non-empty so that legacy points that rely
  # on the lookiar_url field are never invalidated.
  #
  # url type:   { "url" => "https://..." }
  # media types: { "file_url" => "...", "file_name" => "...", "mime_type" => "..." }
  VALID_URL_REGEX      = /\Ahttps?:\/\/.+/i.freeze
  CONTENT_DATA_URL_MAX = 2048
  FILE_NAME_MAX        = 255
  MIME_TYPE_MAX        = 127
  private_constant :VALID_URL_REGEX, :CONTENT_DATA_URL_MAX, :FILE_NAME_MAX, :MIME_TYPE_MAX

  def content_data_matches_schema
    return if content_type.blank?

    cd = content_data
    # Empty content_data is allowed — legacy points use lookiar_url instead.
    return unless cd.is_a?(Hash) && cd.present?

    case content_type
    when "url"
      url = cd["url"].to_s
      if url.blank?
        errors.add(:content_data, "debe incluir 'url' para tipo url")
      elsif url.length > CONTENT_DATA_URL_MAX
        errors.add(:content_data, "'url' no puede superar #{CONTENT_DATA_URL_MAX} caracteres")
      elsif !VALID_URL_REGEX.match?(url)
        errors.add(:content_data, "'url' debe comenzar con http:// o https://")
      end
    when "video", "audio", "file"
      file_url  = cd["file_url"].to_s
      file_name = cd["file_name"].to_s
      mime_type = cd["mime_type"].to_s

      errors.add(:content_data, "debe incluir 'file_url'")  if file_url.blank?
      errors.add(:content_data, "debe incluir 'file_name'") if file_name.blank?
      errors.add(:content_data, "debe incluir 'mime_type'") if mime_type.blank?

      if file_url.present?
        if file_url.length > CONTENT_DATA_URL_MAX
          errors.add(:content_data, "'file_url' no puede superar #{CONTENT_DATA_URL_MAX} caracteres")
        elsif !VALID_URL_REGEX.match?(file_url)
          errors.add(:content_data, "'file_url' debe comenzar con http:// o https://")
        end
      end

      if file_name.length > FILE_NAME_MAX
        errors.add(:content_data, "'file_name' no puede superar #{FILE_NAME_MAX} caracteres")
      end

      if mime_type.length > MIME_TYPE_MAX
        errors.add(:content_data, "'mime_type' no puede superar #{MIME_TYPE_MAX} caracteres")
      end
    end
  end

  def activation_polygon_is_valid_geojson
    geom = activation_polygon
    unless geom.is_a?(Hash) &&
           geom["type"] == "Feature" &&
           geom.dig("geometry", "type").in?(%w[Polygon MultiPolygon]) &&
           geom.dig("geometry", "coordinates").is_a?(Array)
      errors.add(:activation_polygon, "debe ser un GeoJSON Feature válido con geometría Polygon o MultiPolygon")
    end
  end

  def dwell_time_required_when_enabled
    return unless requires_dwell_time
    return if dwell_time_seconds.to_i > 0

    errors.add(:dwell_time_seconds, "debe ser mayor a 0 cuando se requiere permanencia")
  end

  # JSONB availability is stored in snake_case (normalize_params converts keys on ingest).
  # Convert back to camelCase so the JS frontend receives keys matching its TypeScript type.
  def camelize_availability(hash)
    return {} unless hash.is_a?(Hash)
    hash.transform_keys { |k| k.to_s.camelize(:lower) }
  end

  # Images are stored with snake_case keys; convert to camelCase for the JS frontend.
  def camelize_images(arr)
    return [] unless arr.is_a?(Array)
    arr.map do |img|
      next unless img.is_a?(Hash)
      {
        id:      img["id"]       || img[:id],
        url:     img["url"]      || img[:url],
        isCover: img["is_cover"] || img[:is_cover] || false,
        position: (img["position"] || img[:position] || 0).to_i
      }
    end.compact
  end
end
