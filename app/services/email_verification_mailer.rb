class EmailVerificationMailer
  CODE_EXPIRY_MINUTES = (User::VERIFICATION_CODE_EXPIRY / 60).to_i

  def self.send_verification_email(user:, code:)
    unless ENV["RESEND_API_KEY"].present?
      Rails.logger.info "=== EMAIL VERIFICATION (dev — no RESEND_API_KEY) ==="
      Rails.logger.info "  To:   #{user.email}"
      Rails.logger.info "  Code: #{code}"
      Rails.logger.info "===================================================="
      return
    end

    ResendClient.deliver(
      from:    ENV["MAIL_FROM"],
      to:      user.email,
      subject: "Tu código de verificación de Ubyca",
      html:    email_html(user: user, code: code)
    )
  end

  def self.email_html(user:, code:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <body style="margin:0;padding:0;background:#f4f4f5;font-family:sans-serif;">
        <table width="100%" cellpadding="0" cellspacing="0">
          <tr><td align="center" style="padding:40px 16px;">
            <table width="560" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;padding:40px;">
              <tr><td>
                <h1 style="margin:0 0 8px;font-size:22px;color:#111827;">Verificá tu correo electrónico</h1>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Para completar tu registro en Ubyca, ingresá el siguiente código de verificación.
                  Tu cuenta no quedará activa hasta que verifiques tu correo.
                </p>
                <div style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;padding:24px;text-align:center;margin:0 0 24px;">
                  <p style="margin:0 0 8px;font-size:13px;color:#6b7280;text-transform:uppercase;letter-spacing:0.1em;">
                    Código de verificación
                  </p>
                  <p style="margin:0;font-size:40px;font-weight:700;color:#111827;letter-spacing:0.25em;">
                    #{code}
                  </p>
                </div>
                <p style="margin:0 0 24px;color:#6b7280;font-size:15px;">
                  Este código es válido por <strong>#{CODE_EXPIRY_MINUTES} minutos</strong>.
                  Si no creaste una cuenta en Ubyca, podés ignorar este correo.
                </p>
                <p style="margin:0;color:#9ca3af;font-size:12px;">
                  Por tu seguridad, nunca compartas este código con nadie.
                  Ubyca nunca te pedirá tu código de verificación.
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
