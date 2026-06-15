class AnalyticsEvent < ApplicationRecord
  # Legacy event types — created by the Public (Studio/app) surface.
  PUBLIC_EVENT_TYPES = %w[radius_enter point_click dwell_started dwell_completed dwell_cancelled].freeze

  # API v1 event types — created by the presence validation engine.
  API_EVENT_TYPES = %w[presence.validated destination.delivered].freeze

  # Smart Proxy event types — emitted by the injected browser script and by the
  # server when fetching the proxied page.  Writable through the dedicated
  # POST /api/public/smart_proxy_events endpoint (not the generic analytics one).
  SMART_PROXY_EVENT_TYPES = %w[
    smart_proxy_opened
    smart_proxy_fetch_success
    smart_proxy_fetch_failed
    smart_proxy_location_requested
    smart_proxy_location_granted
    smart_proxy_location_denied
    smart_proxy_presence_validated
    smart_proxy_presence_failed
    smart_proxy_heartbeat
    smart_proxy_click
    smart_proxy_dwell_completed
    smart_proxy_page_hidden
    smart_proxy_page_visible
  ].freeze

  # Project-level location ping — records presence at project scope without
  # requiring a specific GeoPoint.  geo_point_id is nil for these events.
  PROJECT_EVENT_TYPES = %w[project_location].freeze

  EVENT_TYPES = (PUBLIC_EVENT_TYPES + API_EVENT_TYPES +
                 SMART_PROXY_EVENT_TYPES + PROJECT_EVENT_TYPES).freeze

  # Subset writable through POST /api/analytics_events (public endpoint).
  # Smart Proxy types are excluded — they use a dedicated endpoint.
  PUBLIC_WRITABLE_EVENT_TYPES = (PUBLIC_EVENT_TYPES + API_EVENT_TYPES).freeze

  # Event source — identifies which surface created the event.
  # NULL = legacy public event (created before source tracking was added).
  SOURCES = %w[public api smart_proxy].freeze

  # Unified analytics groups — all access channels map to these two buckets so
  # that Metrics (radiusEntries, clicks, conversion) reflects physical presence
  # regardless of whether the user arrived via the map, API v1, or Smart Proxy.
  ENTRY_EVENTS      = %w[radius_enter presence.validated smart_proxy_opened].freeze
  CONVERSION_EVENTS = %w[point_click destination.delivered smart_proxy_click].freeze

  belongs_to :geo_project,    optional: true
  belongs_to :geo_point,      optional: true
  belongs_to :api_credential, optional: true
  belongs_to :smart_proxy,    optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :session_id, presence: true
  validates :event_date, presence: true
  validates :source,     inclusion: { in: SOURCES }, allow_nil: true

  # Either a project or a smart proxy must be present (but not necessarily both).
  validates :geo_project_id, presence: true, unless: :smart_proxy_id?

  # Deduplicate radius_enter only: 1 entry per (session, project, point, day).
  # API event types are never deduplicated — they form a full audit trail.
  validates :session_id, uniqueness: {
    scope:   %i[geo_project_id geo_point_id event_type event_date],
    message: "evento ya registrado para esta sesión"
  }, if: -> { event_type == "radius_enter" }
end
