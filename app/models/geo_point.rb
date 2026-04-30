class GeoPoint < ApplicationRecord
  belongs_to :geo_project, inverse_of: :geo_points

  validates :latitude,          presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude,         presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :activation_radius, numericality: { greater_than: 0, only_integer: true }
  validates :order,             numericality: { greater_than_or_equal_to: 0, only_integer: true }

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
      active:           active,
      order:            order,
    }
  end
end
