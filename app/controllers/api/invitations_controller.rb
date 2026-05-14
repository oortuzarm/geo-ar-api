module Api
  class InvitationsController < ApplicationController
    before_action :authenticate_user!, only: %i[create resend destroy]
    before_action :require_owner!,     only: %i[create resend destroy]

    # POST /api/invitations
    def create
      email = params[:email].to_s.downcase.strip
      role  = params[:role].to_s

      unless Invitation::INVITABLE_ROLES.include?(role)
        render json: { error: "Rol inválido. Permitidos: editor, viewer." }, status: :unprocessable_entity
        return
      end

      if current_organization.users.exists?(email: email)
        render json: { error: "Este usuario ya es miembro de la organización." }, status: :unprocessable_entity
        return
      end

      invitation, raw_token = Invitation.generate_for(
        organization: current_organization,
        email:        email,
        role:         role,
        invited_by:   current_user
      )

      InvitationMailer.send_invitation(invitation: invitation, token: raw_token)

      render json: invitation_json(invitation), status: :created
    end

    # POST /api/invitations/:id/resend
    def resend
      invitation = current_organization.invitations.find(params[:id])

      if invitation.accepted?
        render json: { error: "Esta invitación ya fue aceptada." }, status: :unprocessable_entity
        return
      end

      raw_token = invitation.refresh_token!
      InvitationMailer.send_invitation(invitation: invitation, token: raw_token)

      render json: invitation_json(invitation)
    end

    # DELETE /api/invitations/:id
    def destroy
      invitation = current_organization.invitations.find(params[:id])

      if invitation.accepted?
        render json: { error: "Esta invitación ya fue aceptada." }, status: :unprocessable_entity
        return
      end

      invitation.destroy!
      head :no_content
    end

    # GET /api/invitations/accept/:token
    # Public — returns invitation preview so the frontend can show a confirmation screen.
    def show_accept
      invitation = Invitation.find_by_token(params[:token])

      if invitation.nil?
        render json: { error: "Invitación no encontrada." }, status: :not_found
        return
      end

      render json: {
        organizationName: invitation.organization.name,
        email:            invitation.email,
        role:             invitation.role,
        expired:          invitation.expired?,
        accepted:         invitation.accepted?
      }
    end

    # POST /api/invitations/accept
    # Public — registers or links a user to the invited organization.
    def accept
      invitation = Invitation.find_by_token(params[:token].to_s)

      if invitation.nil?
        render json: { error: "Invitación no encontrada." }, status: :not_found
        return
      end

      if invitation.expired?
        render json: { error: "Esta invitación ya expiró. Pedí al owner que la reenvíe." },
               status: :unprocessable_entity
        return
      end

      if invitation.accepted?
        render json: { error: "Esta invitación ya fue aceptada." }, status: :unprocessable_entity
        return
      end

      user = User.find_by(email: invitation.email)

      if user
        accept_existing_user(user, invitation)
      else
        accept_new_user(invitation)
      end
    end

    private

    # --- accept helpers ---

    def accept_existing_user(user, invitation)
      if user.memberships.exists?(organization: invitation.organization)
        render json: { error: "Ya sos miembro de esta organización." }, status: :unprocessable_entity
        return
      end

      if user.memberships.exists?
        render json: { error: "Ya pertenecés a otra organización. El soporte multi-org no está disponible aún." },
               status: :unprocessable_entity
        return
      end

      ActiveRecord::Base.transaction do
        user.memberships.create!(organization: invitation.organization, role: invitation.role)
        invitation.accept!
      end

      render json: { message: "Te uniste a #{invitation.organization.name} correctamente." }
    end

    def accept_new_user(invitation)
      password     = params[:password].to_s
      confirmation = params[:password_confirmation].to_s

      if password.length < 8
        render json: { error: "La contraseña debe tener al menos 8 caracteres." },
               status: :unprocessable_entity
        return
      end

      unless password == confirmation
        render json: { error: "Las contraseñas no coinciden." }, status: :unprocessable_entity
        return
      end

      user = nil
      ActiveRecord::Base.transaction do
        user = User.create!(
          email:                 invitation.email,
          password:              password,
          password_confirmation: confirmation,
          role:                  "user",
          status:                "active"
        )
        user.memberships.create!(organization: invitation.organization, role: invitation.role)
        invitation.accept!
      end

      session[:user_id] = user.id
      render json: {
        message: "Cuenta creada. Bienvenido/a a #{invitation.organization.name}.",
        user:    { id: user.id, email: user.email, role: user.role, status: user.status }
      }, status: :created
    end

    # --- serializers ---

    def invitation_json(inv)
      {
        id:        inv.id,
        email:     inv.email,
        role:      inv.role,
        expired:   inv.expired?,
        accepted:  inv.accepted?,
        expiresAt: inv.expires_at.iso8601(3),
        createdAt: inv.created_at.iso8601(3)
      }
    end
  end
end
