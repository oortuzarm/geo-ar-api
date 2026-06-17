class Organization < ApplicationRecord
  has_many :memberships,    dependent: :destroy
  has_many :users,          through:   :memberships
  has_many :invitations,    dependent: :destroy
  has_many :api_credentials, dependent: :destroy
  has_many :geo_projects,   dependent: :destroy
  has_many :smart_proxies, dependent: :destroy

  before_validation :generate_slug_from_name

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9\-]+\z/,
                             message: "solo puede contener letras minúsculas, números y guiones" }

  private

  def generate_slug_from_name
    return if slug.present?

    base      = name.to_s.parameterize.presence || "organizacion"
    candidate = base
    counter   = 1

    while Organization.where.not(id: id).exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter  += 1
    end

    self.slug = candidate
  end
end
