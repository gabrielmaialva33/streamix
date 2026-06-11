defmodule StreamixWeb.Api.V1.SubtitlesController do
  @moduledoc """
  Serves an external subtitle as WebVTT for the player to load via
  `loadExternalSubtitle`.

  The player calls `GET /api/v1/subtitles/:imdb_id?lang=pt-BR`; we
  resolve it through `Streamix.Subtitles` (provider chain + cache) and
  return `text/vtt`. Anonymous + rate-limited like the rest of `/api`:
  the payload is just public subtitle text. `204 No Content` when no
  subtitle is available so the client cleanly offers none.
  """

  use StreamixWeb, :controller

  alias Streamix.Subtitles

  @imdb_re ~r/^tt\d{6,9}$/

  def show(conn, %{"imdb_id" => imdb_id} = params) do
    lang = sanitize_lang(params["lang"])

    if Regex.match?(@imdb_re, imdb_id) do
      respond(conn, Subtitles.get_vtt(imdb_id, lang))
    else
      conn |> put_status(:bad_request) |> json(%{error: "invalid imdb_id"})
    end
  end

  defp respond(conn, {:ok, vtt}) do
    conn
    |> put_resp_content_type("text/vtt")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, vtt)
  end

  defp respond(conn, :not_found), do: send_resp(conn, 204, "")
  defp respond(conn, :disabled), do: send_resp(conn, 204, "")

  # Keep the lang tag to a safe shape (e.g. "pt-BR", "en"); fall back to
  # pt-BR. Avoids passing arbitrary input down to the providers.
  defp sanitize_lang(lang) when is_binary(lang) do
    if Regex.match?(~r/^[a-zA-Z]{2}(-[a-zA-Z]{2})?$/, lang), do: lang, else: "pt-BR"
  end

  defp sanitize_lang(_), do: "pt-BR"
end
