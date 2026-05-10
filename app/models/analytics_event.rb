class AnalyticsEvent < ApplicationRecord
  EVENT_TYPES = %w[radius_enter point_click].freeze

  belongs_to :geo_project
  belongs_to :geo_point

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :session_id, presence: true
  validates :event_date, presence: true
  validates :session_id, uniqueness: {
    scope: %i[geo_project_id geo_point_id event_type event_date],
    message: "evento ya registrado para esta sesión"
  }
end
