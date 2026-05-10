class GeoPoint < ApplicationRecord
  belongs_to :geo_project, inverse_of: :geo_points
  has_many   :analytics_events, dependent: :destroy

  validates :latitude,          presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude,         presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :activation_radius, numericality: { greater_than: 0, only_integer: true }
  validates :order,             numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Public variant: intentionally excludes lookiarUrl so the destination
  # URL is never exposed in the HTML payload. The URL is returned only
  # after server-side validation via POST .../geo_points/:id/access.
  def as_public_api_json
    as_api_json.except(:lookiarUrl)
  end

  def as_api_json
    {
      id:               id,
      geoProjectId:     geo_project_id,
      name:             name,
      lookiarUrl:       lookiar_url,
      latitude:         latitude,
      longitude:        longitude,
      activationRadius: activation_radius,
      image:            image,
      description:      description,
      instructions:     instructions,
      buttonText:       button_text,
      active:           active,
      order:            order,
      availability:     camelize_availability(availability)
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
