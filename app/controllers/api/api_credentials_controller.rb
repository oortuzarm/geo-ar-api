module Api
  class ApiCredentialsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_credential!, only: %i[update regenerate_secret]

    # GET /api/api_credentials
    # Returns all credentials for the current user's organization.
    # Never includes secret or digest fields.
    def index
      credentials = current_organization.api_credentials.order(created_at: :desc)
      render json: credentials.map { |c| credential_json(c) }
    end

    # POST /api/api_credentials
    # Body: { name: "...", scopes: ["analytics:read", ...] }
    # Returns the credential WITH the plaintext secret — shown only once.
    def create
      name   = params[:name].to_s.strip
      scopes = Array(params[:scopes])

      if name.blank?
        render json: { error: "El nombre es obligatorio." }, status: :unprocessable_entity
        return
      end

      if scopes.empty?
        render json: { error: "Debes seleccionar al menos un scope." }, status: :unprocessable_entity
        return
      end

      invalid = scopes - ApiCredential::VALID_SCOPES
      if invalid.any?
        render json: { error: "Scopes inválidos: #{invalid.join(', ')}" }, status: :unprocessable_entity
        return
      end

      # ── Plan enforcement ──────────────────────────────────────────────────────
      unless current_user.api_access_enabled?
        render json: { error: "Tu plan no incluye acceso a la API." }, status: :forbidden
        return
      end

      limit = current_user.effective_api_credentials_limit
      if limit && current_organization.api_credentials.where(status: "active").count >= limit
        render json: { error: "Alcanzaste el límite de credenciales API de tu plan." }, status: :unprocessable_entity
        return
      end

      credential, plaintext_secret = ApiCredential.build_with_secret(
        organization:    current_organization,
        name:            name,
        scopes:          scopes,
        created_by_user: current_user
      )
      credential.save!

      render json: credential_json(credential).merge(secret: plaintext_secret), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.first || "Error al crear la credencial." },
             status: :unprocessable_entity
    end

    # PATCH /api/api_credentials/:id
    # Body: { active: true|false }
    # Maps active → status "active"/"revoked".
    # Refuses to reactivate an expired credential.
    def update
      unless params.key?(:active)
        render json: { error: "El parámetro 'active' es obligatorio." }, status: :unprocessable_entity
        return
      end

      active = params[:active]

      if active && @credential.expired?
        render json: { error: "No se puede reactivar una credencial expirada." }, status: :unprocessable_entity
        return
      end

      @credential.update!(status: active ? "active" : "revoked")
      render json: credential_json(@credential)
    end

    # POST /api/api_credentials/:id/regenerate_secret
    # Generates a new secret, preserving the current one in previous_key_secret_digest
    # for a 1-hour grace window so existing integrations don't break immediately.
    # Returns the new plaintext secret — shown only once.
    def regenerate_secret
      new_secret = "#{ApiCredential::KEY_SECRET_PREFIX}#{SecureRandom.alphanumeric(48)}"

      @credential.update!(
        previous_key_secret_digest: @credential.key_secret_digest,
        previous_key_expires_at:    1.hour.from_now,
        key_secret_digest:          ApiCredential.digest(new_secret)
      )

      render json: { id: @credential.id, secret: new_secret }
    end

    private

    def set_credential!
      @credential = current_organization.api_credentials.find(params[:id])
    end

    # Serializes a credential for API responses.
    # key_public → key  |  active? → active  |  never includes digest fields.
    def credential_json(c)
      {
        id:         c.id,
        name:       c.name,
        key:        c.key_public,
        active:     c.active?,
        scopes:     c.scopes,
        lastUsedAt: c.last_used_at&.iso8601(3),
        createdAt:  c.created_at.iso8601(3)
      }
    end
  end
end
