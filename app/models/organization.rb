class Organization < ApplicationRecord
  has_many :memberships,    dependent: :destroy
  has_many :users,          through:   :memberships
  has_many :invitations,    dependent: :destroy
  has_many :api_credentials, dependent: :destroy
  has_many :smart_links,    dependent: :destroy

  before_validation :generate_slug_from_name

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9\-]+\z/,
                             message: "solo puede contener letras minúsculas, números y guiones" }

  private

  def generate_slug_from_name
    self.slug = slug.present? ? slug.to_s.parameterize : name.to_s.parameterize
  end
end
