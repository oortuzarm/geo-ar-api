class ApplicationController < ActionController::API
  before_action :normalize_params

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "Not found" }, status: :not_found
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { error: "Validation failed", details: e.record.errors.as_json }, status: :unprocessable_entity
  end

  rescue_from ActionController::ParameterMissing do |e|
    render json: { error: e.message }, status: :bad_request
  end

  private

  # Convert camelCase keys sent by the JS frontend to snake_case for Rails strong params.
  # e.g. coverImage → cover_image, geoProjectId → geo_project_id
  def normalize_params
    normalize_hash!(params)
  end

  def normalize_hash!(hash)
    hash.keys.each do |key|
      new_key = key.to_s.underscore
      value   = hash.delete(key)
      hash[new_key] = normalize_value(value)
    end
    hash
  end

  def normalize_value(value)
    case value
    when ActionController::Parameters then normalize_hash!(value)
    when Array then value.map { |v| normalize_value(v) }
    else value
    end
  end
end
