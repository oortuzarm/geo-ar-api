class GeoPoint < ApplicationRecord
  CONTENT_TYPES = %w[url video audio file].freeze

  belongs_to :geo_project, inverse_of: :geo_points
  has_many   :analytics_events, dependent: :destroy

  validates :latitude,          presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude,         presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :activation_radius, numericality: { greater_than: 0, only_integer: true }
  validates :order,             numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :content_type,      inclusion: { in: CONTENT_TYPES }

  # Public variant: excludes content fields so the destination is never
  # exposed in the HTML payload. Content is returned only after server-side
  # validation via POST .../geo_points/:id/access.
  # contentType IS included so the frontend can show the right icon/button.
  def as_public_api_json
    as_api_json.except(:lookiarUrl, :contentData)
  end

  def as_api_json
    {
      id:               id,
      geoProjectId:     geo_project_id,
      name:             name,
      lookiarUrl:       lookiar_url,
      contentType:      content_type,
      contentData:      content_data,
      latitude:         latitude,
      longitude:        longitude,
      activationRadius: activation_radius,
      image:            image,
      description:      description,
      instructions:     instructions,
      buttonText:       button_text,
      active:           active,
      order:            order,
      availability:     camelize_availability(availability),
    }
  end

  private

  # JSONB availability is stored in snake_case (normalize_params converts keys on ingest).
  # Convert back to camelCase so the JS frontend receives keys matching its TypeScript type.
  def camelize_availability(hash)
    return {} unless hash.is_a?(Hash)
    hash.transform_keys { |k| k.to_s.camelize(:lower) }
  end
end
