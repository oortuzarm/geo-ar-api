class GeoProject < ApplicationRecord
  STATUSES           = %w[draft active inactive].freeze
  COMMUNITY_STATUSES = %w[pending approved rejected hidden].freeze

  belongs_to :user,         optional: true
  belongs_to :organization

  has_many :geo_points,        -> { order(:order) }, dependent: :destroy, inverse_of: :geo_project
  has_many :analytics_events,  dependent: :destroy
  has_many :smart_links,       foreign_key: :project_id, dependent: :destroy, inverse_of: :project

  VIEW_MODES = %w[fit_points custom].freeze

  validates :title,            presence: true, length: { maximum: 255 }
  validates :status,           inclusion: { in: STATUSES,           message: "debe ser draft, active o inactive" }
  validates :community_status, inclusion: { in: COMMUNITY_STATUSES, message: "debe ser pending, approved, rejected o hidden" }

  validates :subtitle,     length: { maximum: 255  }, allow_nil: true
  validates :description,  length: { maximum: 2000 }, allow_nil: true
  validates :cover_image,  length: { maximum: 2048 }, allow_nil: true
  validates :how_to_get,   length: { maximum: 1000 }, allow_nil: true
  validates :share_text,   length: { maximum: 500  }, allow_nil: true

  before_validation :normalize_view_mode
  before_save       :reset_community_status_on_enable

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
      communityEnabled:        community_enabled,
      communityStatus:         community_status,
      createdAt:               created_at.iso8601(3),
      updatedAt:               updated_at.iso8601(3),
      geoPointIds:             geo_points.pluck(:id),
      publicInitialViewMode:   public_initial_view_mode,
      publicInitialCenterLat:  public_initial_center_lat&.to_f,
      publicInitialCenterLng:  public_initial_center_lng&.to_f,
      publicInitialZoom:       public_initial_zoom,
      projectLogoUrl:          project_logo_url,
      projectLogoZoom:         project_logo_zoom
    }
  end

  def as_api_json_with_points
    as_api_json.merge(geoPoints: geo_points.map(&:as_api_json))
  end

  # Public serializer — omits internal/admin-only fields not needed by the
  # public experience page: communityStatus (admin moderation state),
  # and createdAt/updatedAt (internal metadata).
  def as_public_api_json
    as_api_json.except(:communityStatus, :createdAt, :updatedAt)
  end

  private

  def normalize_view_mode
    self.public_initial_view_mode = "fit_points" if public_initial_view_mode.blank?
  end

  # When community_enabled transitions false → true, reset community_status to "pending"
  # so admin re-reviews, UNLESS it was already approved (user toggled off briefly, then back on).
  def reset_community_status_on_enable
    return unless community_enabled_changed? && community_enabled?
    self.community_status = "pending" unless community_status == "approved"
  end
end
