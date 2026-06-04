class AnalyticsEvent < ApplicationRecord
  # Legacy event types — created by the Public (Studio/app) surface.
  PUBLIC_EVENT_TYPES = %w[radius_enter point_click dwell_started dwell_completed dwell_cancelled].freeze

  # API v1 event types — created by the presence validation engine.
  API_EVENT_TYPES = %w[presence.validated destination.delivered].freeze

  # Smart Links event types — created server-side by SmartLinkValidationService.
  # Not writable through the public analytics endpoint.
  SMART_LINK_EVENT_TYPES = %w[smart_link_opened smart_link_validation_passed smart_link_validation_failed smart_link_redirected].freeze

  EVENT_TYPES = (PUBLIC_EVENT_TYPES + API_EVENT_TYPES + SMART_LINK_EVENT_TYPES).freeze

  # Subset writable through POST /api/analytics_events (public endpoint).
  # Smart Link types are excluded — they are only created server-side.
  PUBLIC_WRITABLE_EVENT_TYPES = (PUBLIC_EVENT_TYPES + API_EVENT_TYPES).freeze

  # Event source — identifies which surface created the event.
  # NULL = legacy public event (created before source tracking was added).
  SOURCES = %w[public api smart_link].freeze

  # Unified analytics groups — all access channels map to these two buckets so
  # that Metrics (radiusEntries, clicks, conversion) reflects physical presence
  # regardless of whether the user arrived via the map, API v1, or a Smart Link.
  ENTRY_EVENTS      = %w[radius_enter presence.validated smart_link_validation_passed].freeze
  CONVERSION_EVENTS = %w[point_click destination.delivered].freeze

  belongs_to :geo_project
  belongs_to :geo_point, optional: true
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
