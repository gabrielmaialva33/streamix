defmodule Streamix.Programming.ProgramBuilder do
  @moduledoc """
  Turns a station's query into a program: discovery over the public Xtream
  providers (every viewer may play them), only titles the public catalog
  still lists with a real feature runtime, in an order shuffled per station
  and per day so the same films do not always open the loop.
  """

  alias Streamix.{AI, Catalog, Providers}
  alias Streamix.Programming.Station

  @candidates 80
  @max_items 40
  @min_items 5
  @min_runtime 60 * 60
  @max_runtime 4 * 60 * 60

  @doc "A program for the station, or an error when discovery fails or finds too little."
  @spec build(Station.t(), Date.t()) :: {:ok, [map()]} | {:error, term()}
  def build(%Station{} = station, %Date{} = day) do
    with [_ | _] = provider_ids <- public_provider_ids(),
         {:ok, %{results: results}} <-
           AI.discover(station.query, :movies, provider_ids: provider_ids, limit: @candidates) do
      results
      |> Enum.map(& &1.id)
      |> Catalog.list_public_movies_by_ids(show_adult: false)
      |> Enum.filter(&feature_runtime?/1)
      |> Enum.take(@max_items)
      |> shuffle({station.slug, day})
      |> Enum.map(&item/1)
      |> enough()
    else
      [] -> {:error, :no_public_providers}
      {:error, _reason} = error -> error
    end
  end

  defp public_provider_ids do
    for %{provider_type: :xtream, is_active: true, id: id} <- Providers.list_public_providers(),
        do: id
  end

  defp feature_runtime?(%{duration_secs: secs}) when is_integer(secs),
    do: secs >= @min_runtime and secs <= @max_runtime

  defp feature_runtime?(_movie), do: false

  # Deterministic per station and day: a rebuild on the same day keeps the
  # order, the next day's rebuild reshuffles it.
  defp shuffle(movies, seed) do
    hash = :erlang.phash2(seed)
    state = :rand.seed_s(:exsss, {hash, hash * 7 + 1, hash * 13 + 3})

    {keyed, _state} =
      Enum.map_reduce(movies, state, fn movie, state ->
        {roll, state} = :rand.uniform_s(state)
        {{roll, movie}, state}
      end)

    keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  defp item(movie) do
    %{
      "movie_id" => movie.id,
      "duration" => movie.duration_secs,
      "title" => movie.title || movie.name,
      "year" => movie.year,
      "poster" => movie.stream_icon
    }
  end

  defp enough(items) when length(items) >= @min_items, do: {:ok, items}
  defp enough(_items), do: {:error, :too_few_titles}
end
