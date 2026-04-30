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

ActiveRecord::Schema[7.2].define(version: 2026_04_29_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

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
    t.index ["status"], name: "index_geo_projects_on_status"
  end

  add_foreign_key "geo_points", "geo_projects"
end
