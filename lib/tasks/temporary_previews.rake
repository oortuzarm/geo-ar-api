namespace :temporary_previews do
  desc "Delete all expired temporary previews (expires_at < now)"
  task cleanup: :environment do
    count = TemporaryPreview.where("expires_at < ?", Time.current).delete_all
    puts "temporary_previews:cleanup — deleted #{count} expired preview(s)."
  end
end
