module LiveVisitsQueryable
  extend ActiveSupport::Concern

  # Wraps last_hour_delta_percent so a calculation error never brings down the
  # endpoint.  Returns nil on failure.
  def safe_last_hour_delta(active_now_count)
    last_hour_delta_percent(active_now_count)
  rescue => e
    Rails.logger.error "[LIVE_VISITS] last_hour_delta failed: #{e.class}: #{e.message}"
    nil
  end

  # Wraps peak_today so a calculation error never brings down the endpoint.
  # Returns nil on failure.
  def safe_peak_today
    peak_today
  rescue => e
    Rails.logger.error "[LIVE_VISITS] peak_today failed: #{e.class}: #{e.message}"
    nil
  end

  private

  # Compares active_now against the snapshot closest to 1 hour ago.
  #
  # Looks for a project-level snapshot (geo_point_id: nil) within ±8 minutes of
  # the 1-hour mark.  With 5-minute sampling this window always covers 2-3
  # candidates; we take the most recent one.
  #
  # Returns nil when no suitable snapshot exists (e.g. first hour after deploy).
  #
  # Formula:
  #   past > 0               → ((now - past) / past.to_f * 100).round
  #   past == 0, now > 0     → 100
  #   both zero              → 0
  def last_hour_delta_percent(active_now_count)
    target_time = 1.hour.ago

    snapshot = LiveVisitSnapshot
      .where(geo_project_id: @project.id, geo_point_id: nil)
      .where(sampled_at: (target_time - 8.minutes)..(target_time + 8.minutes))
      .order(:sampled_at)
      .last

    return nil if snapshot.nil?

    past_count = snapshot.active_count
    if past_count > 0
      ((active_now_count - past_count) / past_count.to_f * 100).round
    elsif active_now_count > 0
      100
    else
      0
    end
  end

  # Resolves the timezone to use for peak_today calculations.
  # Priority: project owner's saved time_zone → server Time.zone fallback.
  # ActiveSupport::TimeZone[] returns nil for unknown/invalid names, so any
  # bad value stored in users.time_zone falls through to the server default.
  def project_time_zone
    owner_tz = @project.user&.time_zone.presence
    ActiveSupport::TimeZone[owner_tz] || Time.zone
  end

  # Returns the hour block with the highest simultaneous active count today, e.g.:
  #   { label: "14:00–15:00", count: 34 }
  # Returns nil when no snapshots exist for today.
  #
  # Uses project-level snapshots (geo_point_id: nil).  Each snapshot records the
  # number of users active AT that moment, so grouping by hour and taking the
  # MAX gives the peak concurrency — not a count of events or session records.
  #
  # "Today" and hour labels are expressed in the project owner's timezone.
  def peak_today
    tz  = project_time_zone
    now = Time.current.in_time_zone(tz)

    today_start = now.beginning_of_day
    today_end   = now.end_of_day

    snapshots = LiveVisitSnapshot
      .where(geo_project_id: @project.id, geo_point_id: nil)
      .where(sampled_at: today_start..today_end)
      .pluck(:sampled_at, :active_count)

    return nil if snapshots.empty?

    counts_by_hour = snapshots
      .group_by { |ts, _| ts.in_time_zone(tz).beginning_of_hour }
      .transform_values { |group| group.map(&:last).max }

    hour_start, count = counts_by_hour.max_by { |_, cnt| cnt }

    {
      label: "#{hour_start.strftime('%H:%M')}–#{(hour_start + 1.hour).strftime('%H:%M')}",
      count: count
    }
  end
end
