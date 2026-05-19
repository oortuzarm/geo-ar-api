namespace :temporary_previews do
  desc "Delete expired temporary previews and their associated Blob Storage files"
  task cleanup: :environment do
    expired = TemporaryPreview.where("expires_at < ?", Time.current)
    total   = expired.count

    if total.zero?
      puts "temporary_previews:cleanup — nothing to clean up."
      next
    end

    blob_token_present = ENV["BLOB_READ_WRITE_TOKEN"].present?
    unless blob_token_present
      Rails.logger.warn "[BLOB_CLEANUP] BLOB_READ_WRITE_TOKEN not set — blob files will NOT be deleted"
    end

    deleted_rows  = 0
    deleted_blobs = 0
    skipped_blobs = 0
    failed_blobs  = 0

    expired.find_each do |preview|
      # Extract every internal blob URL from the stored payload.
      blob_urls = BlobStorageClient.extract_blob_urls(preview.payload)

      blob_urls.each do |url|
        # Skip if the URL is also referenced by a real project — don't delete shared assets.
        unless BlobStorageClient.exclusive_to_temporary_previews?(url)
          Rails.logger.info "[BLOB_CLEANUP] Skipping #{url} — referenced by a real project"
          skipped_blobs += 1
          next
        end

        # Skip silently (already warned once above) when token is absent.
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
          # Never let a blob failure block the row deletion.
        end
      end

      preview.destroy!
      deleted_rows += 1
    end

    parts = [
      "#{deleted_rows}/#{total} previews deleted",
      "#{deleted_blobs} blob(s) deleted",
      skipped_blobs > 0 ? "#{skipped_blobs} skipped" : nil,
      failed_blobs  > 0 ? "#{failed_blobs} blob deletion(s) failed" : nil
    ].compact

    puts "temporary_previews:cleanup — #{parts.join(", ")}."
  end
end
