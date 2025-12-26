defmodule StreamixWeb.UserSessionHTML do
  use StreamixWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:streamix, Streamix.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
