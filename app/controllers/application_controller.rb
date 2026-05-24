class ApplicationController < ActionController::API
  before_action :normalize_params

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: "Not found" }, status: :not_found
  end

  rescue_from UncaughtThrowError do |e|
    raise e unless e.tag == :abort
    head :internal_server_error unless performed?
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { error: "Validation failed", details: e.record.errors.as_json }, status: :unprocessable_entity
  end

  rescue_from ActionController::ParameterMissing do |e|
    render json: { error: e.message }, status: :bad_request
  end

  private

  def current_user
    return nil unless session[:user_id]
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def authenticate_user!
    unless current_user
      Rails.logger.warn "[AUTH_DENIED] controller=#{self.class.name} action=#{action_name} path=#{request.path}"
      render json: { error: "No autenticado" }, status: :unauthorized
      throw :abort
    end
  end

  def current_membership
    return nil unless current_user
    @current_membership ||= current_user.memberships.includes(:organization).first
  end

  def current_organization
    current_membership&.organization
  end

  def require_owner!
    unless current_membership&.role == "owner"
      render json: { error: "Solo el owner puede realizar esta acción." }, status: :forbidden
      throw :abort
    end
  end

  def authorize_project!(project)
    unless project.user_id == current_user.id || current_user.role == "admin"
      Rails.logger.warn "[GEO_PROJECT_OWNERSHIP_DENIED] user_id=#{current_user.id} " \
                        "project_id=#{project.id} owner_id=#{project.user_id} action=#{action_name}"
      render json: { error: "No autorizado" }, status: :forbidden
      throw :abort
    end
  end

  # Blocks location creation when subscription is inactive or the plan limit is reached.
  # Call as a before_action on geo_points#create.
  # Admins are exempt — they manage on behalf of other users and have no plan of their own.
  def enforce_location_limit!
    user = current_user
    return if user.role == "admin"

    # Subscription must be active (active or in-trial).
    unless user.subscription_active?
      reason = user.trial_expired? ? "Tu período de prueba ha expirado." : "Tu suscripción no está activa."
      Rails.logger.warn "[LOCATION_LIMIT_BLOCKED] user_id=#{user.id} status=#{user.subscription_status} reason=inactive"
      render json: { error: reason }, status: :forbidden
      throw :abort
    end

    limit = user.effective_location_limit
    return if limit.nil? # unlimited — no further checks needed

    count = user.current_location_count
    if count >= limit
      Rails.logger.warn "[LOCATION_LIMIT_REACHED] user_id=#{user.id} count=#{count} limit=#{limit}"
      render json: {
        error: "Has alcanzado el límite de ubicaciones de tu plan (#{limit}).",
        currentCount: count,
        limit: limit
      }, status: :forbidden
      throw :abort
    end
  end

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
