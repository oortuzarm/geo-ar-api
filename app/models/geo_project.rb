class GeoProject < ApplicationRecord
  STATUSES = %w[draft active inactive].freeze

  has_many :geo_points,        -> { order(:order) }, dependent: :destroy, inverse_of: :geo_project
  has_many :analytics_events,  dependent: :destroy

  VIEW_MODES = %w[fit_points custom].freeze

  validates :title,  presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES, message: "debe ser draft, active o inactive" }

  before_validation :normalize_view_mode

  scope :publicly_visible, -> { where(status: "active") }

  def as_api_json
    {
      id:                      id,
      title:                   title,
      subtitle:                subtitle,
      description:             description,
      coverImage:              cover_image,
      howToGet:                how_to_get,
      shareText:               share_text,
      status:                  status,
      createdAt:               created_at.iso8601(3),
      updatedAt:               updated_at.iso8601(3),
      geoPointIds:             geo_points.pluck(:id),
      publicInitialViewMode:   public_initial_view_mode,
      publicInitialCenterLat:  public_initial_center_lat&.to_f,
      publicInitialCenterLng:  public_initial_center_lng&.to_f,
      publicInitialZoom:       public_initial_zoom
    }
  end

  def as_api_json_with_points
    as_api_json.merge(geoPoints: geo_points.map(&:as_api_json))
  end

  private

  def normalize_view_mode
    self.public_initial_view_mode = "fit_points" if public_initial_view_mode.blank?
  end
end
