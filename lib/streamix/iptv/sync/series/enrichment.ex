defmodule Streamix.Iptv.Sync.Series.Enrichment do
  @moduledoc """
  Series metadata enrichment from detailed Xtream info and TMDB fallback search.
  """

  alias Streamix.Iptv.{Series, TmdbClient}
  alias Streamix.Iptv.Sync.Helpers
  alias Streamix.Repo

  @doc """
  Updates missing series metadata from a detailed provider response.
  """
  def update_series_from_info(%Series{} = series, info) when is_map(info) do
    tmdb_id = resolve_tmdb_id(series, info)

    attrs =
      %{}
      |> maybe_update(:tmdb_id, tmdb_id, series.tmdb_id)
      |> maybe_update(:plot, info["plot"], series.plot)
      |> maybe_update(:youtube_trailer, info["youtube_trailer"], series.youtube_trailer)

    if map_size(attrs) > 0 do
      series
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()
    else
      :ok
    end
  end

  def update_series_from_info(_series, _info), do: :ok

  defp resolve_tmdb_id(series, info) do
    case Helpers.to_string_or_nil(info["tmdb_id"]) do
      nil -> search_tmdb_for_series(series.name, series.year)
      "" -> search_tmdb_for_series(series.name, series.year)
      id -> id
    end
  end

  defp search_tmdb_for_series(name, year) when is_binary(name) do
    opts = if year, do: [year: year], else: []

    case TmdbClient.search_series(name, opts) do
      {:ok, %{"results" => [first | _]}} ->
        to_string(first["id"])

      _ ->
        nil
    end
  end

  defp search_tmdb_for_series(_name, _year), do: nil

  defp maybe_update(attrs, _key, nil, _current), do: attrs
  defp maybe_update(attrs, _key, "", _current), do: attrs
  defp maybe_update(attrs, _key, _new, current) when not is_nil(current), do: attrs
  defp maybe_update(attrs, key, new, _current), do: Map.put(attrs, key, new)
end
