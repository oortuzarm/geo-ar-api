class AnalyticsEvent < ApplicationRecord
  # Legacy event types — created by the Public (Studio/app) surface.
  PUBLIC_EVENT_TYPES = %w[radius_enter point_click dwell_started dwell_completed dwell_cancelled].freeze

  # API v1 event types — created by the presence validation engine.
  API_EVENT_TYPES = %w[presence.validated destination.delivered].freeze

  EVENT_TYPES = (PUBLIC_EVENT_TYPES + API_EVENT_TYPES).freeze

  # Event source — identifies which surface created the event.
  # NULL = legacy public event (created before source tracking was added).
  SOURCES = %w[public api].freeze

  belongs_to :geo_project
  belongs_to :geo_point
  belongs_to :api_credential, optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :session_id, presence: true
  validates :event_date, presence: true
  validates :source,     inclusion: { in: SOURCES }, allow_nil: true

  # Deduplicate radius_enter only: 1 entry per (session, project, point, day).
  # API event types are never deduplicated — they form a full audit trail.
  validates :session_id, uniqueness: {
    scope:   %i[geo_project_id geo_point_id event_type event_date],
    message: "evento ya registrado para esta sesión"
  }, if: -> { event_type == "radius_enter" }
end
