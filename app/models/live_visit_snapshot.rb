class LiveVisitSnapshot < ApplicationRecord
  belongs_to :geo_project
  belongs_to :geo_point, optional: true

  # All writes go through insert_all in LiveVisitSnapshotJob, bypassing AR
  # validations intentionally for throughput.  This model exists for queries.
end
