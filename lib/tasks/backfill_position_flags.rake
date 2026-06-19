namespace :analytics do
  # One-time backfill for project_location events that predate the
  # had_inside_position / had_outside_position columns (deployed 2026-06-19).
  #
  # Each historical row stores a single coordinate (last known position of the
  # day). That coordinate is passed through GeoEngine to set exactly one of the
  # two flags, reproducing the same single-snapshot semantics the old
  # classification used.
  #
  # Limitation: mixed sessions CANNOT be reconstructed from historical data.
  # A session that was both inside and outside on the same day was overwritten
  # to its last position, so the trajectory is lost. Each historical record will
  # receive exactly one flag (had_inside OR had_outside, never both).
  # Mixed classification is accurate only for data recorded after the deploy.
  #
  # Usage:
  #   rails analytics:backfill_position_flags
  desc "Backfill had_inside_position / had_outside_position on existing project_location events"
  task backfill_position_flags: :environment do
    scope = AnalyticsEvent
      .where(event_type: "project_location")
      .where(had_inside_position: false, had_outside_position: false)
      .where.not(latitude: nil, longitude: nil)
      .where(latitude: -90.0..90.0, longitude: -180.0..180.0)
      .where("NOT (latitude = 0 AND longitude = 0)")

    total   = scope.count
    updated = 0
    skipped = 0

    puts "Backfilling #{total} project_location events..."
    puts "NOTE: Mixed detection requires post-deploy data. Each historical record receives exactly one flag."
    puts ""

    # Cache active GeoPoints per project to avoid repeated DB queries for
    # projects that appear across many events.
    points_by_project = {}

    scope.find_each(batch_size: 500) do |event|
      active_points = points_by_project.fetch(event.geo_project_id) do
        pts = GeoPoint.where(geo_project_id: event.geo_project_id, active: true).to_a
        points_by_project[event.geo_project_id] = pts
        pts
      end

      if active_points.empty?
        skipped += 1
        next
      end

      is_inside = active_points.any? { |pt| GeoEngine.inside_boundary?(pt, event.latitude, event.longitude) }

      event.update_columns(
        had_inside_position:  is_inside,
        had_outside_position: !is_inside
      )
      updated += 1
    end

    puts "Done."
    puts "  Updated : #{updated}"
    puts "  Skipped : #{skipped} (project had no active GeoPoints — flags remain false)"
    puts ""
    puts "Mixed classification will only be accurate for data recorded after the deploy of this feature."
  end
end
