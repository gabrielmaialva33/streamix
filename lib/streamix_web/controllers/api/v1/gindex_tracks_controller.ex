defmodule StreamixWeb.Api.V1.GindexTracksController do
  @moduledoc """
  Returns the audio + subtitle track list for a GIndex VOD file.

  Replaces the heavy "spawn a 2nd AVPlayer just to enumerate tracks"
  flow on the frontend with a server-side `ffprobe` cache. First call
  per file does the probe (~200 ms); subsequent calls hit the
  `track_metadata` jsonb in the row and return in <10 ms.

  Anonymous access on purpose: the response is purely informational
  (track index + language + codec name). Rate limit is the same as
  the rest of `/api`.
  """

  use StreamixWeb, :controller

  alias Streamix.Gindex.MetadataProbe

  def show(conn, %{"type" => type, "id" => id}) do
    with {:ok, type_atom} <- parse_type(type),
         {id_int, ""} <- Integer.parse(id),
         {:ok, tracks} <- MetadataProbe.fetch(type_atom, id_int) do
      json(conn, tracks)
    else
      :error ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid id"})

      {:error, :unsupported_type} ->
        conn |> put_status(:bad_request) |> json(%{error: "unsupported type"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "content not found"})

      {:error, :not_gindex} ->
        # Choki content has its own track enumeration via hls.js — there's
        # nothing for us to probe server-side. Tell the client so it can
        # fall back to the runtime path.
        conn |> put_status(:not_found) |> json(%{error: "tracks not available"})

      {:error, :probing} ->
        # Cache miss — probe was scheduled in background. Frontend
        # bails silently; the next visitor (or a reload after the
        # task finishes) will hit the populated cache.
        conn
        |> put_status(:accepted)
        |> json(%{status: "probing", retry_after: 5})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "probe failed", reason: inspect(reason)})
    end
  end

  defp parse_type("movie"), do: {:ok, :movie}
  defp parse_type("episode"), do: {:ok, :episode}
  defp parse_type(_), do: {:error, :unsupported_type}
end
