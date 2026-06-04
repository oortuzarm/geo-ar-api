class SmartLinkGeoPoint < ApplicationRecord
  belongs_to :smart_link
  belongs_to :geo_point

  validates :geo_point_id, uniqueness: { scope: :smart_link_id }
end
