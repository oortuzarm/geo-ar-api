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

ActiveRecord::Schema[7.2].define(version: 2026_06_10_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "analytics_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "geo_project_id"
    t.uuid "geo_point_id"
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
    t.string "source"
    t.uuid "api_credential_id"
    t.string "user_ref"
    t.jsonb "context_metadata"
    t.string "failure_reason"
    t.uuid "smart_proxy_id"
    t.index ["api_credential_id"], name: "index_analytics_events_on_api_credential_id"
    t.index ["geo_project_id", "geo_point_id", "event_type", "session_id", "event_date"], name: "idx_analytics_events_radius_enter_uniqueness", unique: true, where: "((event_type)::text = 'radius_enter'::text)"
    t.index ["geo_project_id", "session_id", "event_date"], name: "idx_analytics_events_project_location_uniqueness", unique: true, where: "((event_type)::text = 'project_location'::text)"
    t.index ["geo_project_id"], name: "index_analytics_events_on_geo_project_id"
    t.index ["smart_proxy_id"], name: "index_analytics_events_on_smart_proxy_id"
    t.index ["source"], name: "index_analytics_events_on_source"
  end

  create_table "api_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "name", null: false
    t.string "key_public", null: false
    t.string "key_secret_digest", null: false
    t.string "previous_key_secret_digest"
    t.datetime "previous_key_expires_at"
    t.string "scopes", default: [], null: false, array: true
    t.string "status", default: "active", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.uuid "created_by_user_id"
    t.datetime "revoked_at"
    t.uuid "revoked_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key_public"], name: "index_api_credentials_on_key_public", unique: true
    t.index ["organization_id"], name: "index_api_credentials_on_organization_id"
    t.index ["status"], name: "index_api_credentials_on_status"
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
    t.index ["geo_point_id", "inside_radius", "last_seen_at"], name: "idx_live_visits_active"
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
    t.string "activation_mode", default: "radius", null: false
    t.jsonb "activation_polygon"
    t.string "destination_category"
    t.index ["activation_mode"], name: "index_geo_points_on_activation_mode"
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
    t.uuid "organization_id", null: false
    t.string "project_logo_url"
    t.float "project_logo_zoom"
    t.float "project_logo_position_x"
    t.float "project_logo_position_y"
    t.index ["community_enabled", "community_status"], name: "index_geo_projects_on_community"
    t.index ["organization_id"], name: "index_geo_projects_on_organization_id"
    t.index ["status"], name: "index_geo_projects_on_status"
    t.index ["user_id"], name: "index_geo_projects_on_user_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
    t.integer "lock_type", limit: 2
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_good_jobs_on_created_at"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_on_discarded", order: :desc, where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["id"], name: "index_good_jobs_on_unfinished_or_errored", where: "((finished_at IS NULL) OR (error IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["queue_name"], name: "index_good_jobs_on_queue_name"
    t.index ["scheduled_at", "queue_name"], name: "index_good_jobs_on_scheduled_at_and_queue_name"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "idempotency_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "api_credential_id", null: false
    t.string "idempotency_key", null: false
    t.string "endpoint", null: false
    t.integer "response_status"
    t.text "response_body"
    t.datetime "expires_at", null: false
    t.datetime "locked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_credential_id", "idempotency_key"], name: "idx_idempotency_keys_on_credential_and_key", unique: true
    t.index ["expires_at"], name: "index_idempotency_keys_on_expires_at"
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
    t.string "slug", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
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
    t.boolean "is_onboarding_plan", default: false, null: false
    t.boolean "api_access_enabled", default: true, null: false
    t.integer "api_credentials_limit"
    t.index ["is_visible"], name: "index_plans_on_is_visible"
    t.index ["slug"], name: "index_plans_on_slug", unique: true
    t.index ["sort_order"], name: "index_plans_on_sort_order"
  end

  create_table "project_live_visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "geo_project_id", null: false
    t.string "session_id", null: false
    t.float "lat", null: false
    t.float "lng", null: false
    t.float "accuracy"
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["geo_project_id", "last_seen_at"], name: "idx_project_live_visits_active"
    t.index ["geo_project_id", "session_id"], name: "index_project_live_visits_on_project_and_session", unique: true
  end

  create_table "site_configs", force: :cascade do |t|
    t.string "key", null: false
    t.string "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_site_configs_on_key", unique: true
  end

  create_table "smart_link_geo_points", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "smart_link_id", null: false
    t.uuid "geo_point_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["geo_point_id"], name: "index_smart_link_geo_points_on_geo_point_id"
    t.index ["smart_link_id", "geo_point_id"], name: "index_smart_link_geo_points_on_smart_link_id_and_geo_point_id", unique: true
  end

  create_table "smart_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "project_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "scope_type", default: "project", null: false
    t.string "destination_type", default: "external_url", null: false
    t.string "destination_url"
    t.string "status", default: "active", null: false
    t.jsonb "ui_config", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "organization_id", null: false
    t.index ["organization_id", "slug"], name: "index_smart_links_on_organization_id_and_slug", unique: true
    t.index ["project_id"], name: "index_smart_links_on_project_id"
    t.index ["status"], name: "index_smart_links_on_status"
    t.index ["user_id"], name: "index_smart_links_on_user_id"
  end

  create_table "smart_proxies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "user_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "destination_url", null: false
    t.string "proxy_status", default: "unknown", null: false
    t.boolean "active", default: true, null: false
    t.string "custom_domain"
    t.string "domain_status", default: "pending"
    t.string "ssl_status", default: "pending"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "compatibility_status", default: "pending", null: false
    t.integer "compatibility_score", default: 0, null: false
    t.jsonb "compatibility_report", default: {}
    t.datetime "compatibility_checked_at"
    t.index ["active"], name: "index_smart_proxies_on_active"
    t.index ["compatibility_status"], name: "index_smart_proxies_on_compatibility_status"
    t.index ["custom_domain"], name: "index_smart_proxies_on_custom_domain", unique: true, where: "(custom_domain IS NOT NULL)"
    t.index ["organization_id", "slug"], name: "index_smart_proxies_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_smart_proxies_on_organization_id"
    t.index ["proxy_status"], name: "index_smart_proxies_on_proxy_status"
    t.index ["user_id"], name: "index_smart_proxies_on_user_id"
  end

  create_table "smart_proxy_live_visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "smart_proxy_id", null: false
    t.string "session_id", null: false
    t.float "lat", null: false
    t.float "lng", null: false
    t.float "accuracy"
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["last_seen_at"], name: "index_smart_proxy_live_visits_on_last_seen_at"
    t.index ["smart_proxy_id", "session_id"], name: "index_smart_proxy_live_visits_on_proxy_and_session", unique: true
    t.index ["smart_proxy_id"], name: "index_smart_proxy_live_visits_on_smart_proxy_id"
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
    t.string "time_zone", default: "UTC", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["plan_id"], name: "index_users_on_plan_id"
    t.index ["subscription_status"], name: "index_users_on_subscription_status"
  end

  add_foreign_key "analytics_events", "api_credentials"
  add_foreign_key "analytics_events", "smart_proxies", on_delete: :nullify
  add_foreign_key "api_credentials", "organizations"
  add_foreign_key "api_credentials", "users", column: "created_by_user_id"
  add_foreign_key "api_credentials", "users", column: "revoked_by_user_id"
  add_foreign_key "geo_point_live_visits", "geo_points"
  add_foreign_key "geo_point_live_visits", "geo_projects"
  add_foreign_key "geo_points", "geo_projects"
  add_foreign_key "geo_projects", "organizations"
  add_foreign_key "geo_projects", "users"
  add_foreign_key "idempotency_keys", "api_credentials"
  add_foreign_key "invitations", "organizations"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "password_reset_tokens", "users"
  add_foreign_key "smart_link_geo_points", "geo_points"
  add_foreign_key "smart_link_geo_points", "smart_links"
  add_foreign_key "smart_links", "geo_projects", column: "project_id"
  add_foreign_key "smart_links", "organizations"
  add_foreign_key "smart_links", "users"
  add_foreign_key "smart_proxies", "organizations"
  add_foreign_key "smart_proxies", "users"
  add_foreign_key "smart_proxy_live_visits", "smart_proxies"
  add_foreign_key "users", "onboarding_categories", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_industry_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_objective_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_org_size_id", on_delete: :nullify
  add_foreign_key "users", "onboarding_options", column: "onboarding_org_type_id", on_delete: :nullify
  add_foreign_key "users", "plans"
end
