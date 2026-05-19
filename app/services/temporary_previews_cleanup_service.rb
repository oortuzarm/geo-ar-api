class TemporaryPreviewsCleanupService
  THROTTLE_KEY    = "temporary_previews_cleanup:last_run"
  THROTTLE_TTL    = 10.minutes
  CACHE_LOCK_TTL  = 11.minutes # must exceed THROTTLE_TTL to survive Rails.cache eviction

  # Run inline cleanup (throttled). Safe to call from any request — never raises.
  # Returns :ran, :throttled, or :error.
  def self.run_inline
    return :throttled if throttled?

    begin
      Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: CACHE_LOCK_TTL)
      result = new.run
      Rails.logger.info "[PREVIEW_CLEANUP] inline #{result}"
      :ran
    rescue => e
      Rails.logger.warn "[PREVIEW_CLEANUP] inline cleanup failed — #{e.message}"
      :error
    end
  end

  # Run synchronously and return a result hash. Called by rake task and run_inline.
  # Never raises — all failures are caught and logged.
  def run
    expired = TemporaryPreview.where("expires_at < ?", Time.current)
    total   = expired.count
    return { total: 0 } if total.zero?

    blob_token_present = ENV["BLOB_READ_WRITE_TOKEN"].present?
    unless blob_token_present
      Rails.logger.warn "[BLOB_CLEANUP] BLOB_READ_WRITE_TOKEN not set — blob files will NOT be deleted"
    end

    deleted_rows  = 0
    deleted_blobs = 0
    skipped_blobs = 0
    failed_blobs  = 0

    expired.find_each do |preview|
      blob_urls = BlobStorageClient.extract_blob_urls(preview.payload)

      blob_urls.each do |url|
        unless BlobStorageClient.exclusive_to_temporary_previews?(url)
          Rails.logger.info "[BLOB_CLEANUP] Skipping #{url} — referenced by a real project"
          skipped_blobs += 1
          next
        end

        unless blob_token_present
          skipped_blobs += 1
          next
        end

        begin
          BlobStorageClient.delete!(url)
          Rails.logger.info "[BLOB_CLEANUP] Deleted blob #{url}"
          deleted_blobs += 1
        rescue => e
          Rails.logger.warn "[BLOB_CLEANUP] Failed to delete #{url} — #{e.message}"
          failed_blobs += 1
        end
      end

      preview.destroy!
      deleted_rows += 1
    end

    { total: total, deleted_rows: deleted_rows, deleted_blobs: deleted_blobs,
      skipped_blobs: skipped_blobs, failed_blobs: failed_blobs }
  end

  private

  def self.throttled?
    Rails.cache.exist?(THROTTLE_KEY)
  end
end
