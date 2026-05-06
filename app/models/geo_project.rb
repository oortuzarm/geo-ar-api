class GeoProject < ApplicationRecord
  STATUSES = %w[draft active inactive].freeze

  has_many :geo_points,        -> { order(:order) }, dependent: :destroy, inverse_of: :geo_project
  has_many :analytics_events,  dependent: :destroy

  validates :title,  presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES, message: "debe ser draft, active o inactive" }

  scope :publicly_visible, -> { where(status: "active") }

  def as_api_json
    {
      id:          id,
      title:       title,
      subtitle:    subtitle,
      description: description,
      coverImage:  cover_image,
      howToGet:    how_to_get,
      shareText:   share_text,
      status:      status,
      createdAt:   created_at.iso8601(3),
      updatedAt:   updated_at.iso8601(3),
      geoPointIds: geo_points.pluck(:id),
    }
  end

  def as_api_json_with_points
    as_api_json.merge(geoPoints: geo_points.map(&:as_api_json))
  end
end
