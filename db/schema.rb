# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_05_27_110000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "analytics_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "geo_project_id", null: false
    t.uuid "geo_point_id", null: false
    t.string "event_type", null: false
    t.string "session_id", null: false
    t.date "event_date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "latitude"
    t.float "longitude"
    t.string "country"
    t.string "city"
    t.string "commune"
    t.index ["geo_project_id", "geo_point_id", "event_type", "session_id", "event_date"], name: "idx_analytics_events_radius_enter_uniqueness", unique: true, where: "((event_type)::text = 'radius_enter'::text)"
    t.index ["geo_project_id"], name: "index_analytics_events_on_geo_project_id"
  end

  create_table "geo_point_live_visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "geo_project_id", null: false
    t.uuid "geo_point_id", null: false
    t.string "session_id", null: false
    t.float "lat", null: false
    t.float "lng", null: false
    t.float "accuracy"
    t.boolean "inside_radius", default: false, null: false
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["geo_point_id", "session_id"], name: "index_geo_point_live_visits_on_geo_point_id_and_session_id", unique: true
    t.index ["geo_project_id"], name: "index_geo_point_live_visits_on_geo_project_id"
    t.index ["inside_radius"], name: "index_geo_point_live_visits_on_inside_radius"
    t.index ["last_seen_at"], name: "index_geo_point_live_visits_on_last_seen_at"
  end

  create_table "geo_points", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "geo_project_id", null: false
    t.string "name", default: "Nuevo punto", null: false
    t.string "lookiar_url", default: "", null: false
    t.float "latitude", null: false
    t.float "longitude", null: false
    t.integer "activation_radius", default: 50, null: false
    t.text "image"
    t.text "description"
    t.text "instructions"
    t.boolean "active", default: true, null: false
    t.integer "order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "availability", default: {}, null: false
    t.string "button_text"
    t.string "content_type", default: "url", null: false
    t.jsonb "content_data", default: {}, null: false
    t.jsonb "images"
    t.boolean "requires_dwell_time", default: false, null: false
    t.integer "dwell_time_seconds", default: 0, null: false
    t.index ["geo_project_id", "order"], name: "index_geo_points_on_geo_project_id_and_order"
    t.index ["geo_project_id"], name: "index_geo_points_on_geo_project_id"
  end

  create_table "geo_projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", default: "Nuevo proyecto GPS", null: false
    t.string "subtitle"
    t.text "description"
    t.text "cover_image"
    t.text "how_to_get"
    t.string "status", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "share_text"
    t.string "public_initial_view_mode", default: "fit_points"
    t.decimal "public_initial_center_lat", precision: 10, scale: 6
    t.decimal "public_initial_center_lng", precision: 10, scale: 6
    t.integer "public_initial_zoom"
    t.uuid "user_id"
    t.boolean "community_enabled", default: false, null: false
    t.string "community_status", default: "pending", null: false
    t.index ["community_enabled", "community_status"], name: "index_geo_projects_on_community"
    t.index ["status"], name: "index_geo_projects_on_status"
    t.index ["user_id"], name: "index_geo_projects_on_user_id"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "invited_by_id", null: false
    t.string "email", null: false
    t.string "role", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["organization_id", "email"], name: "index_invitations_on_organization_id_and_email"
    t.index ["organization_id"], name: "index_invitations_on_organization_id"
    t.index ["token_digest"], name: "index_invitations_on_token_digest", unique: true
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "organization_id", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "onboarding_categories", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "description"
    t.string "icon_name"
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.integer "usage_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_onboarding_categories_on_active"
    t.index ["position"], name: "index_onboarding_categories_on_position"
    t.index ["slug"], name: "index_onboarding_categories_on_slug", unique: true
  end

  create_table "onboarding_options", force: :cascade do |t|
    t.string "option_group", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.integer "usage_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_onboarding_options_on_active"
    t.index ["option_group", "slug"], name: "index_onboarding_options_on_option_group_and_slug", unique: true
    t.index ["option_group"], name: "index_onboarding_options_on_option_group"
  end

  create_table "organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "password_reset_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_password_reset_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_password_reset_tokens_on_user_id"
  end

  create_table "plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.decimal "monthly_price", precision: 10, scale: 2, null: false
    t.integer "annual_discount_percent", default: 0, null: false
    t.decimal "yearly_price_computed", precision: 10, scale: 2
    t.integer "location_limit"
    t.boolean "has_trial", default: false, null: false
    t.integer "trial_days"
    t.boolean "is_visible", default: true, null: false
    t.boolean "is_recommended", default: false, null: false
    t.boolean "apply_to_existing_users", default: false, null: false
    t.integer "sort_order", default: 0, null: false
    t.boolean "is_custom", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "public_description"
    t.jsonb "features", default: [], null: false
    t.string "cta_text"
    t.string "cta_url"
    t.jsonb "features_config", default: {}, null: false
    t.index ["is_visible"], name: "index_plans_on_is_visible"
    t.index ["slug"], name: "index_plans_on_slug", unique: true
    t.index ["sort_order"], name: "index_plans_on_sort_order"
  end

  create_table "site_configs", force: :cascade do |t|
    t.string "key", null: false
    t.string "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_site_configs_on_key", unique: true
  end

  create_table "temporary_previews", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "token", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "claimed_at"
    t.string "demo_project_id"
    t.index ["claimed_at"], name: "index_temporary_previews_on_claimed_at"
    t.index ["demo_project_id"], name: "index_temporary_previews_on_demo_project_id"
    t.index ["expires_at"], name: "index_temporary_previews_on_expires_at"
    t.index ["token"], name: "index_temporary_previews_on_token", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "user", null: false
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "company"
    t.string "job_title"
    t.string "country"
    t.uuid "plan_id"
    t.string "subscription_status", default: "trial", null: false
    t.datetime "trial_starts_at"
    t.datetime "trial_ends_at"
    t.integer "custom_location_limit"
    t.boolean "onboarding_completed", default: false, null: false
    t.integer "onboarding_category_id"
    t.integer "onboarding_industry_id"
    t.integer "onboarding_org_type_id"
    t.integer "onboarding_org_size_id"
    t.integer "onboarding_objective_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["plan_id"], name: "index_users_on_plan_id"
    t.index ["subscription_status"], name: "index_users_on_subscription_status"
  end

  add_foreign_key "geo_point_live_visits", "geo_points"
  add_foreign_key "geo_point_live_visits", "geo_projects"
  add_foreign_key "geo_points", "geo_projects"
  add_foreign_key "geo_projects", "users"
  add_foreign_key "invitations", "organizations"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "password_reset_tokens", "users"
  add_foreign_key "users", "onboarding_categories", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_industry_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_objective_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_org_size_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_org_type_id", on_delete: :nullify
  add_foreign_key "users", "plans"
end
