class GeoPoint < ApplicationRecord
  CONTENT_TYPES = %w[url video audio file].freeze

  belongs_to :geo_project, inverse_of: :geo_points
  has_many   :analytics_events, dependent: :destroy

  validates :latitude,           presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude,          presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :activation_radius,  numericality: { greater_than: 0, only_integer: true }
  validates :order,              numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :content_type,       inclusion: { in: CONTENT_TYPES }
  validates :dwell_time_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate  :dwell_time_required_when_enabled

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
      availability:       camelize_availability(availability),
      requiresDwellTime:  requires_dwell_time,
      dwellTimeSeconds:   dwell_time_seconds,
      createdAt:          created_at.iso8601(3)
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
