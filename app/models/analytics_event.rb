class AnalyticsEvent < ApplicationRecord
  EVENT_TYPES = %w[radius_enter point_click].freeze

  belongs_to :geo_project
  belongs_to :geo_point

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :session_id, presence: true
  validates :event_date, presence: true
  # Deduplicate radius_enter only: 1 entry per (session, project, point, day).
  # point_click is NOT deduplicated — every real click must generate a new record.
  validates :session_id, uniqueness: {
    scope:   %i[geo_project_id geo_point_id event_type event_date],
    message: "evento ya registrado para esta sesión"
  }, if: -> { event_type == "radius_enter" }
end
