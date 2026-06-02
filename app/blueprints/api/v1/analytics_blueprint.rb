module Api
  module V1
    # Serializes analytics query rows for API v1 responses.
    #
    # Two named views — no default fields, so only the named view's fields are
    # rendered.  Both views accept an :active_counts option (Hash of
    # geo_point_id => integer) injected by the controller for live session data.
    #
    # Usage:
    #   AnalyticsBlueprint.render_as_hash(rows, view: :location_stats, active_counts: counts)
    #   AnalyticsBlueprint.render_as_hash(rows, view: :intensity_point)
    class AnalyticsBlueprint < Blueprinter::Base
      # ── /analytics/locations ────────────────────────────────────────────────
      # Input rows: geo_point AR objects with aggregated analytics columns
      # (radius_entries, clicks, unique_enterers, unique_clickers).
      view :location_stats do
        field :locationId    do |r| r.id end
        field :locationName  do |r| r.name end
        field :radiusEntries do |r| r.radius_entries.to_i end
        field :clicks        do |r| r.clicks.to_i end
        field :conversionPct do |r|
          ue = r.unique_enterers.to_i
          uc = r.unique_clickers.to_i
          ue > 0 ? (uc.to_f / ue * 100).round : 0
        end
        field :activeNow do |r, opts|
          (opts[:active_counts] || {})[r.id] || 0
        end
      end

      # ── /analytics/intensity ────────────────────────────────────────────────
      # Input rows: geo_point AR objects with entry_count aggregate.
      view :intensity_point do
        field :locationId   do |r| r.id end
        field :locationName do |r| r.name end
        field :lat          do |r| r.latitude end
        field :lng          do |r| r.longitude end
        field :entryCount   do |r| r.entry_count.to_i end
      end
    end
  end
end
