module Api
  class MembersController < ApplicationController
    before_action :authenticate_user!
    before_action :require_owner!, only: %i[update destroy]

    # GET /api/members
    # Returns active members + pending invitations for the dashboard.
    def index
      org = current_organization

      members = org.memberships
                   .includes(:user)
                   .order("memberships.created_at ASC")

      invitations = org.invitations
                       .where(accepted_at: nil)
                       .order("invitations.created_at DESC")

      render json: {
        organization: org_json(org),
        members:      members.map    { |m| member_json(m) },
        invitations:  invitations.map { |i| invitation_json(i) }
      }
    end

    # PATCH /api/members/:id
    # Owner changes a member's role. Cannot promote to owner or demote last owner.
    def update
      membership = current_organization.memberships.find(params[:id])
      new_role   = params[:role].to_s

      unless Membership::ROLES.include?(new_role)
        render json: { error: "Rol inválido." }, status: :unprocessable_entity
        return
      end

      if new_role == "owner"
        render json: { error: "No se puede asignar el rol owner desde este endpoint." },
               status: :unprocessable_entity
        return
      end

      if membership.owner? && sole_owner?
        render json: { error: "No podés cambiar el rol del único owner de la organización." },
               status: :unprocessable_entity
        return
      end

      membership.update!(role: new_role)
      render json: member_json(membership)
    end

    # DELETE /api/members/:id
    # Owner removes a member. Cannot remove self if sole owner, cannot remove last owner.
    def destroy
      membership = current_organization.memberships.find(params[:id])

      if membership.id == current_membership.id
        render json: { error: "No podés eliminarte a vos mismo." }, status: :unprocessable_entity
        return
      end

      if membership.owner? && sole_owner?
        render json: { error: "No podés eliminar al único owner de la organización." },
               status: :unprocessable_entity
        return
      end

      membership.destroy!
      head :no_content
    end

    private

    def sole_owner?
      current_organization.memberships.where(role: "owner").count <= 1
    end

    def org_json(org)
      { id: org.id, name: org.name }
    end

    def member_json(m)
      {
        id:       m.id,
        userId:   m.user_id,
        email:    m.user.email,
        role:     m.role,
        joinedAt: m.created_at.iso8601(3)
      }
    end

    def invitation_json(inv)
      {
        id:          inv.id,
        email:       inv.email,
        role:        inv.role,
        expired:     inv.expired?,
        expiresAt:   inv.expires_at.iso8601(3),
        createdAt:   inv.created_at.iso8601(3)
      }
    end
  end
end
