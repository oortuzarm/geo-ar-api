require "test_helper"

# Tests for POST /api/analytics_events (public endpoint — no auth required).
# Focuses on context_metadata enrichment introduced for Analytics → Destinations.
class Api::AnalyticsEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user    = User.create!(email: "ae_#{SecureRandom.hex(4)}@example.com",
                            password: "pw", role: "user", status: "active")
    @project = GeoProject.create!(title: "Test", status: "active", user: @user)
    @point   = GeoPoint.create!(
      geo_project: @project, name: "P", latitude: -34.0, longitude: -58.0, order: 0
    )
    @sid = SecureRandom.uuid
    @base_params = {
      projectId:  @project.id,
      pointId:    @point.id,
      eventType:  "point_click",
      sessionId:  @sid,
    }
  end

  # Helper: find the event created for the current @sid (unique per test).
  def last_event
    AnalyticsEvent.find_by!(session_id: @sid)
  end

  # ── Legacy payload (no context_metadata) ──────────────────────────────────

  test "point_click without context_metadata succeeds and stores nil metadata" do
    post "/api/analytics_events", params: @base_params, as: :json
    assert_response :created
    event = last_event
    assert_equal "point_click",  event.event_type
    assert_nil                   event.context_metadata
  end

  # ── context_metadata: content_type only ───────────────────────────────────

  test "point_click with content_type url stores metadata" do
    post "/api/analytics_events",
         params: @base_params.merge(contextMetadata: { contentType: "url" }),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal "url", meta["content_type"]
    refute meta.key?("destination_category")
  end

  test "point_click with content_type video stores metadata" do
    post "/api/analytics_events",
         params: @base_params.merge(contextMetadata: { contentType: "video" }),
         as: :json
    assert_response :created
    assert_equal "video", last_event.context_metadata["content_type"]
  end

  test "point_click with content_type audio stores metadata" do
    post "/api/analytics_events",
         params: @base_params.merge(contextMetadata: { contentType: "audio" }),
         as: :json
    assert_response :created
    assert_equal "audio", last_event.context_metadata["content_type"]
  end

  test "point_click with content_type file stores metadata" do
    post "/api/analytics_events",
         params: @base_params.merge(contextMetadata: { contentType: "file" }),
         as: :json
    assert_response :created
    assert_equal "file", last_event.context_metadata["content_type"]
  end

  # ── context_metadata: content_type + destination_category ─────────────────

  test "point_click with url + whatsapp stores both fields" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: { contentType: "url", destinationCategory: "whatsapp" }
         ),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal "url",      meta["content_type"]
    assert_equal "whatsapp", meta["destination_category"]
  end

  test "point_click with url + reservation stores both fields" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: { contentType: "url", destinationCategory: "reservation" }
         ),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal "url",         meta["content_type"]
    assert_equal "reservation", meta["destination_category"]
  end

  test "point_click with video + no destination_category omits destination field" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: { contentType: "video", destinationCategory: nil }
         ),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal "video", meta["content_type"]
    refute meta.key?("destination_category")
  end

  # ── Security: unknown keys are dropped ────────────────────────────────────

  test "unknown context_metadata keys are silently dropped" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: {
             contentType:         "url",
             destinationCategory: "whatsapp",
             secretField:         "injection attempt",
             anotherKey:          "value"
           }
         ),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal %w[content_type destination_category], meta.keys.sort
  end

  test "invalid content_type value is not stored" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: { contentType: "malicious_type" }
         ),
         as: :json
    assert_response :created
    # context_metadata should be nil (no valid keys remained)
    assert_nil last_event.context_metadata
  end

  test "invalid destination_category value is not stored" do
    post "/api/analytics_events",
         params: @base_params.merge(
           contextMetadata: { contentType: "url", destinationCategory: "invalid_category" }
         ),
         as: :json
    assert_response :created
    meta = last_event.context_metadata
    assert_equal "url", meta["content_type"]
    refute meta.key?("destination_category")
  end

  # ── Other event types still work (backward compat) ────────────────────────

  test "radius_enter without context_metadata succeeds" do
    post "/api/analytics_events",
         params: @base_params.merge(eventType: "radius_enter"),
         as: :json
    assert_response :created
    assert_equal "radius_enter", last_event.event_type
  end

  test "radius_enter with context_metadata stores it (forward compat)" do
    post "/api/analytics_events",
         params: @base_params.merge(
           eventType:      "radius_enter",
           contextMetadata: { contentType: "url" }
         ),
         as: :json
    assert_response :created
    assert_equal "url", last_event.context_metadata["content_type"]
  end

  test "all destination_category values are accepted" do
    %w[website whatsapp form reservation ecommerce social map coupon custom].each do |cat|
      sid = SecureRandom.uuid
      post "/api/analytics_events",
           params: @base_params.merge(
             sessionId:       sid,
             contextMetadata: { contentType: "url", destinationCategory: cat }
           ),
           as: :json
      assert_response :created, "expected 201 for destination_category=#{cat}"
      event = AnalyticsEvent.find_by!(session_id: sid)
      assert_equal cat, event.context_metadata["destination_category"]
    end
  end
end
