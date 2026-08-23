defmodule StreamixWeb.OnMount.Locale do
  @moduledoc """
  Applies the resolved locale to every LiveView process.

  Gettext locale is process-local, so the browser Plug cannot configure the
  connected LiveView process. This hook mirrors the same account/session policy
  before mount and assigns document-friendly locale metadata for templates.
  """

  import Phoenix.Component, only: [assign: 3]

  alias StreamixWeb.Locale

  def on_mount(:default, _params, session, socket) do
    locale =
      Locale.resolve(
        user_locale(socket.assigns[:current_scope]),
        session["locale"],
        nil
      )
      |> Locale.put()

    {:cont,
     socket
     |> assign(:locale, locale)
     |> assign(:html_lang, Locale.html_lang(locale))
     |> assign(:locale_options, Locale.options())}
  end

  defp user_locale(%{user: %{locale: locale}}), do: locale
  defp user_locale(_scope), do: nil
end
