class LiveVisitSnapshotCleanupJob < ApplicationJob
  queue_as :default

  RETENTION = 7.days

  def perform
    deleted = LiveVisitSnapshot.where("sampled_at < ?", RETENTION.ago).delete_all
    Rails.logger.info "[LiveVisitSnapshotCleanupJob] deleted #{deleted} rows older than #{RETENTION.inspect}"
  end
end
