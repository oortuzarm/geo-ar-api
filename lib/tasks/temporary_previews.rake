namespace :temporary_previews do
  desc "Delete expired temporary previews and their associated Blob Storage files"
  task cleanup: :environment do
    result = TemporaryPreviewsCleanupService.new.run

    if result[:total].zero?
      puts "temporary_previews:cleanup — nothing to clean up."
      next
    end

    r = result
    parts = [
      "#{r[:deleted_rows]}/#{r[:total]} previews deleted",
      "#{r[:deleted_blobs]} blob(s) deleted",
      r[:skipped_blobs] > 0 ? "#{r[:skipped_blobs]} skipped" : nil,
      r[:failed_blobs]  > 0 ? "#{r[:failed_blobs]} blob deletion(s) failed" : nil
    ].compact

    puts "temporary_previews:cleanup — #{parts.join(", ")}."
  end
end
