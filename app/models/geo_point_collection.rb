class GeoPointCollection < ApplicationRecord
  belongs_to :geo_point
  belongs_to :required_geo_point, class_name: "GeoPoint", foreign_key: :required_geo_point_id

  validates :required_geo_point_id, uniqueness: { scope: :geo_point_id }
  validate  :no_self_reference

  private

  def no_self_reference
    return unless required_geo_point_id == geo_point_id
    errors.add(:required_geo_point_id, "no puede ser igual al punto principal")
  end
end
