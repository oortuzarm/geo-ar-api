class InvitationMailer
  ROLE_LABELS = { "editor" => "Editor", "viewer" => "Visualizador" }.freeze

  def self.send_invitation(invitation:, token:)
    accept_link = "#{ENV['FRONTEND_URL']}/accept-invitation/#{token}"
    role_label  = ROLE_LABELS.fetch(invitation.role, invitation.role.capitalize)

    unless ENV["RESEND_API_KEY"].present?
      Rails.logger.info "=== INVITATION LINK (dev — no RESEND_API_KEY) ==="
      Rails.logger.info "  To:   #{invitation.email}"
      Rails.logger.info "  Org:  #{invitation.organization.name}"
      Rails.logger.info "  Role: #{role_label}"
      Rails.logger.info "  Link: #{accept_link}"
      Rails.logger.info "=================================================="
      return
    end

    ResendClient.deliver(
      from:    ENV["MAIL_FROM"],
      to:      invitation.email,
      subject: "Te invitaron a Ubyca",
      html:    email_html(invitation: invitation, accept_link: accept_link, role_label: role_label)
    )
  end

  def self.email_html(invitation:, accept_link:, role_label:)
    org_name = invitation.organization.name

    <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <body style="margin:0;padding:0;background:#f4f4f5;font-family:sans-serif;">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td align="center" style="padding:40px 16px;">
            <table width="560" cellpadding="0" cellspacing="0"
                   style="background:#fff;border-radius:8px;padding:40px;">
              <tr><td>
                <h1 style="margin:0 0 8px;font-size:22px;color:#111827;">
                  Te invitaron a Ubyca
                </h1>
                <p style="margin:0 0 16px;color:#6b7280;font-size:15px;">
                  Fuiste invitado/a a unirte a
                  <strong style="color:#111827;">#{org_name}</strong>
                  como <strong style="color:#111827;">#{role_label}</strong>.
                </p>
                <p style="margin:0 0 28px;color:#6b7280;font-size:14px;">
                  Esta invitación es válida por <strong>7 días</strong>.
                  Si no la esperabas, podés ignorar este correo.
                </p>
                <table cellpadding="0" cellspacing="0"><tr><td>
                  <a href="#{accept_link}"
                     style="display:inline-block;background:#2563eb;color:#fff;padding:12px 28px;
                            border-radius:6px;text-decoration:none;font-weight:600;font-size:15px;">
                    Aceptar invitación
                  </a>
                </td></tr></table>
                <p style="margin:32px 0 0;color:#9ca3af;font-size:12px;">
                  Si el botón no funciona, copiá este link:<br>
                  <a href="#{accept_link}"
                     style="color:#2563eb;word-break:break-all;">#{accept_link}</a>
                </p>
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body>
      </html>
    HTML
  end
  private_class_method :email_html
end
