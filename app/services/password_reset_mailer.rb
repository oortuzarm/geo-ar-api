class PasswordResetMailer
  def self.send_reset_email(user:, token:)
    reset_link = "#{ENV['FRONTEND_URL']}/reset-password/#{token}"

    unless ENV["RESEND_API_KEY"].present?
      Rails.logger.info "=== PASSWORD RESET (dev — no RESEND_API_KEY) ==="
      Rails.logger.info "  To:   #{user.email}"
      Rails.logger.info "  Link: #{reset_link}"
      Rails.logger.info "================================================="
      return
    end

    ResendClient.deliver(
      from:    ENV["MAIL_FROM"],
      to:      user.email,
      subject: "Recuperá tu contraseña de Ubyca",
      html:    email_html(user: user, reset_link: reset_link)
    )
  end

  def self.send_invite_email(user:, token:)
    setup_link = "#{ENV['FRONTEND_URL']}/reset-password/#{token}"

    unless ENV["RESEND_API_KEY"].present?
      Rails.logger.info "=== INVITE EMAIL (dev — no RESEND_API_KEY) ==="
      Rails.logger.info "  To:   #{user.email}"
      Rails.logger.info "  Link: #{setup_link}"
      Rails.logger.info "==============================================="
      return
    end

    ResendClient.deliver(
      from:    ENV["MAIL_FROM"],
      to:      user.email,
      subject: "Te invitaron a Ubyca — activá tu cuenta",
      html:    invite_html(user: user, setup_link: setup_link)
    )
  end

  def self.email_html(user:, reset_link:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <body style="margin:0;padding:0;background:#f4f4f5;font-family:sans-serif;">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td align="center" style="padding:40px 16px;">
            <table width="560" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;padding:40px;">
              <tr><td>
                <h1 style="margin:0 0 8px;font-size:22px;color:#111827;">Recuperá tu contraseña</h1>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Recibimos una solicitud para restablecer la contraseña de tu cuenta
                  <strong>#{user.email}</strong>.
                </p>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Este link es válido por <strong>60 minutos</strong>. Si no lo solicitaste, podés ignorar este correo.
                </p>
                <table cellpadding="0" cellspacing="0"><tr><td>
                  <a href="#{reset_link}"
                     style="display:inline-block;background:#2563eb;color:#fff;padding:12px 28px;border-radius:6px;text-decoration:none;font-weight:600;font-size:15px;">
                    Restablecer contraseña
                  </a>
                </td></tr></table>
                <p style="margin:32px 0 0;color:#9ca3af;font-size:12px;">
                  Si el botón no funciona, copiá este link:<br>
                  <a href="#{reset_link}" style="color:#2563eb;word-break:break-all;">#{reset_link}</a>
                </p>
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body>
      </html>
    HTML
  end
  def self.invite_html(user:, setup_link:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <body style="margin:0;padding:0;background:#f4f4f5;font-family:sans-serif;">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td align="center" style="padding:40px 16px;">
            <table width="560" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;padding:40px;">
              <tr><td>
                <h1 style="margin:0 0 8px;font-size:22px;color:#111827;">Bienvenido/a a Ubyca</h1>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Se creó una cuenta para <strong>#{user.email}</strong>. Hacé clic en el botón
                  para establecer tu contraseña y activar tu cuenta.
                </p>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Este link es válido por <strong>60 minutos</strong>.
                </p>
                <table cellpadding="0" cellspacing="0"><tr><td>
                  <a href="#{setup_link}"
                     style="display:inline-block;background:#2563eb;color:#fff;padding:12px 28px;border-radius:6px;text-decoration:none;font-weight:600;font-size:15px;">
                    Activar cuenta
                  </a>
                </td></tr></table>
                <p style="margin:32px 0 0;color:#9ca3af;font-size:12px;">
                  Si el botón no funciona, copiá este link:<br>
                  <a href="#{setup_link}" style="color:#2563eb;word-break:break-all;">#{setup_link}</a>
                </p>
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body>
      </html>
    HTML
  end
  private_class_method :email_html, :invite_html
end
