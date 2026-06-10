class ProjectLiveVisit < ApplicationRecord
  ACTIVE_WINDOW = 45.seconds

  belongs_to :geo_project

  validates :session_id, presence: true
  validates :lat, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :lng, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :last_seen_at, presence: true

  scope :active_now, -> { where("last_seen_at >= ?", ACTIVE_WINDOW.ago) }
end
