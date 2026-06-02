module Api
  module V1
    class ProjectBlueprint < Blueprinter::Base
      identifier :id

      field :title
      field :subtitle
      field :description
      field :status

      field :coverImage do |project|
        project.cover_image
      end

      field :howToGet do |project|
        project.how_to_get
      end

      field :shareText do |project|
        project.share_text
      end

      field :communityEnabled do |project|
        project.community_enabled
      end

      field :locationCount do |project|
        project.geo_points.size
      end

      field :createdAt do |project|
        project.created_at.iso8601(3)
      end

      field :updatedAt do |project|
        project.updated_at.iso8601(3)
      end
    end
  end
end
