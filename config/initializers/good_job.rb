GoodJob.configure do |config|
  config.cron = {
    live_visit_snapshot: {
      cron:        "*/5 * * * *",
      class:       "LiveVisitSnapshotJob",
      description: "Snapshot active live visits every 5 minutes for delta and peak metrics"
    },
    live_visit_snapshot_cleanup: {
      cron:        "0 3 * * *",
      class:       "LiveVisitSnapshotCleanupJob",
      description: "Delete live visit snapshots older than 7 days"
    }
  }
end
