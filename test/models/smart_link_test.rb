require "test_helper"

class SmartLinkTest < ActiveSupport::TestCase
  setup do
    @user    = User.create!(email: "sl_test_#{SecureRandom.hex(4)}@example.com",
                             password: "password123", role: "user", status: "active")
    @org     = Organization.create!(name: "Test Org #{SecureRandom.hex(4)}")
    @project = GeoProject.create!(title: "Test Project", status: "active", user: @user, organization: @org)
    @point   = GeoPoint.create!(geo_project: @project, latitude: -33.437, longitude: -70.650)
  end

  teardown do
    SmartLinkGeoPoint.delete_all
    SmartLink.delete_all
    GeoPoint.delete_all
    GeoProject.delete_all
    Organization.where(id: @org.id).destroy_all
    User.where(email: @user.email).destroy_all
  end

  # ── Slug generation ────────────────────────────────────────────────────────

  test "generates slug from name when slug is blank" do
    link = build_link(name: "VIP Festival 2026", slug: "")
    link.valid?
    assert_equal "vip-festival-2026", link.slug
  end

  test "normalizes a provided slug" do
    link = build_link(name: "Otro nombre", slug: "Mi Slug Raro")
    link.valid?
    assert_equal "mi-slug-raro", link.slug
  end

  test "preserves a clean slug" do
    link = build_link(name: "Nombre", slug: "mi-slug-limpio")
    link.valid?
    assert_equal "mi-slug-limpio", link.slug
  end

  test "rejects slug with invalid characters after normalization" do
    link = build_link(name: "...", slug: "!!!")
    refute link.valid?
    assert link.errors[:slug].any?
  end

  # ── Validations ────────────────────────────────────────────────────────────

  test "valid with minimum required fields" do
    assert build_link.valid?
  end

  test "requires name" do
    link = build_link(name: "")
    refute link.valid?
    assert link.errors[:name].any?
  end

  test "requires destination_url for external_url type" do
    link = build_link(destination_url: nil)
    refute link.valid?
    assert link.errors[:destination_url].any?
  end

  test "rejects invalid destination_url" do
    link = build_link(destination_url: "not-a-url")
    refute link.valid?
    assert link.errors[:destination_url].any?
  end

  test "accepts https destination_url" do
    link = build_link(destination_url: "https://example.com/path?q=1")
    assert link.valid?
  end

  test "rejects invalid scope_type" do
    link = build_link(scope_type: "unknown")
    refute link.valid?
    assert link.errors[:scope_type].any?
  end

  test "rejects invalid status" do
    link = build_link(status: "deleted")
    refute link.valid?
    assert link.errors[:status].any?
  end

  # ── Slug uniqueness ────────────────────────────────────────────────────────

  test "slug must be unique within same organization" do
    build_link(slug: "my-slug").save!
    duplicate = build_link(slug: "my-slug")
    refute duplicate.valid?
    assert duplicate.errors[:slug].any?
  end

  test "same slug is allowed for different organizations" do
    build_link(slug: "my-slug").save!
    other_org  = Organization.create!(name: "Other Org #{SecureRandom.hex(4)}")
    other_link = SmartLink.new(
      user:            @user,
      organization:    other_org,
      project:         @project,
      name:            "Other Link",
      slug:            "my-slug",
      destination_url: "https://example.com",
      scope_type:      "project",
      status:          "active"
    )
    assert other_link.valid?
    other_org.destroy
  end

  # ── scope_type = geo_points requires associations ─────────────────────────

  test "geo_points scope requires at least one point" do
    link = build_link(scope_type: "geo_points")
    refute link.valid?
    assert link.errors[:base].any?
  end

  test "geo_points scope is valid when a point is built" do
    link = build_link(scope_type: "geo_points")
    link.smart_link_geo_points.build(geo_point_id: @point.id)
    assert link.valid?
  end

  # ── Serialization ─────────────────────────────────────────────────────────

  test "as_api_json includes organizationSlug and publicUrl" do
    link = build_link.tap(&:save!)
    json = link.as_api_json
    assert_equal @org.slug, json[:organizationSlug]
    assert_equal "https://go.ubyca.com/#{@org.slug}/#{link.slug}", json[:publicUrl]
  end

  test "as_api_json includes expected keys" do
    link = build_link.tap(&:save!)
    json = link.as_api_json
    %i[id name slug organizationSlug publicUrl scopeType destinationType destinationUrl
       status projectId geoPointIds uiConfig createdAt updatedAt].each do |key|
      assert json.key?(key), "missing key :#{key}"
    end
  end

  test "as_public_json includes name, slug, organizationSlug, status" do
    json = build_link.tap(&:save!).as_public_json
    assert_equal %w[name organizationSlug slug status].sort, json.keys.map(&:to_s).sort
  end

  private

  def build_link(**attrs)
    SmartLink.new({
      user:            @user,
      organization:    @org,
      project:         @project,
      name:            "Test Link",
      destination_url: "https://example.com",
      scope_type:      "project",
      status:          "active"
    }.merge(attrs))
  end
end
