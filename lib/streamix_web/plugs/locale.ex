defmodule StreamixWeb.Plugs.Locale do
  @moduledoc """
  Applies the account or browser locale to each HTML request.

  Authenticated account preference wins over the session and browser header.
  The resolved value is stored in session so guest/auth transitions and the
  initial LiveView session render use the same language.
  """

  import Plug.Conn

  alias StreamixWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      Locale.resolve(
        user_locale(conn.assigns[:current_scope]),
        get_session(conn, :locale),
        accept_language(conn)
      )
      |> Locale.put()

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  defp user_locale(%{user: %{locale: locale}}), do: locale
  defp user_locale(_scope), do: nil

  defp accept_language(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
  end
end
