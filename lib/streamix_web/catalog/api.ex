defmodule StreamixWeb.Catalog.Api do
  @moduledoc """
  Builds response payloads for the public Catalog API.
  """

  require Logger

  alias Streamix.Iptv
  alias StreamixWeb.Catalog.Params
  alias StreamixWeb.Catalog.Serializer
  alias StreamixWeb.Catalog.StreamUrls

  def featured do
    %{
      featured: Iptv.get_featured_content() |> Serializer.serialize_featured(),
      stats: Iptv.get_public_stats()
    }
  end

  def movies(params) do
    with_global_provider(%{movies: [], total: 0, has_more: false}, fn provider ->
      opts = Params.movies_opts(params)
      movies = Iptv.list_movies(provider.id, opts)
      total = Iptv.count_movies(provider.id, opts)

      %{
        movies: Enum.map(movies, &Serializer.serialize_movie/1),
        total: total,
        has_more: opts[:offset] + length(movies) < total
      }
    end)
  end

  def movie_detail(id) do
    case Iptv.get_public_movie(id) do
      nil ->
        {:error, :not_found}

      movie ->
        {:ok,
         movie |> safe_fetch(&Iptv.fetch_movie_info/1) |> Serializer.serialize_movie_detail()}
    end
  end

  def series(params) do
    with_global_provider(%{series: [], total: 0, has_more: false}, fn provider ->
      opts = Params.series_opts(params)
      series_list = Iptv.list_series(provider.id, opts)
      total = Iptv.count_series(provider.id, opts)

      %{
        series: Enum.map(series_list, &Serializer.serialize_series/1),
        total: total,
        has_more: opts[:offset] + length(series_list) < total
      }
    end)
  end

  def series_detail(id) do
    case Iptv.get_public_series(id) do
      nil ->
        {:error, :not_found}

      series ->
        case Iptv.get_series_with_sync!(series.id) do
          {:ok, series} -> {:ok, Serializer.serialize_series_detail(series)}
          _ -> {:error, :not_found}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def episode_detail(id) do
    case Iptv.get_public_episode(id) do
      nil ->
        {:error, :not_found}

      episode ->
        {:ok,
         episode
         |> safe_fetch(&Iptv.fetch_episode_info/1)
         |> Serializer.serialize_episode_detail()}
    end
  end

  def channels(params) do
    with_global_provider(%{channels: [], total: 0, has_more: false}, fn provider ->
      opts = Params.channels_opts(params)
      channels = Iptv.list_live_channels(provider.id, opts)
      total = Iptv.count_live_channels(provider.id, opts)

      %{
        channels: Enum.map(channels, &Serializer.serialize_channel/1),
        total: total,
        has_more: opts[:offset] + length(channels) < total
      }
    end)
  end

  def channel_detail(id) do
    case Iptv.get_public_channel(id) do
      nil -> {:error, :not_found}
      channel -> {:ok, Serializer.serialize_channel_detail(channel)}
    end
  end

  def categories(params) do
    with_global_provider([], fn provider ->
      provider.id
      |> Iptv.list_categories(Params.category_type(params["type"]))
      |> Enum.map(fn category ->
        %{id: category.id, name: clean_category_name(category.name), type: category.type}
      end)
    end)
  end

  def search(%{"q" => query} = params) when is_binary(query) and byte_size(query) >= 2 do
    query = Params.search_query(query, 200)
    limit = Params.search_limit(params)
    [movies, series, channels] = search_buckets(query, limit, :timer.seconds(5))

    %{
      query: query,
      movies: Enum.map(movies, &Serializer.serialize_ranked_movie/1),
      series: Enum.map(series, &Serializer.serialize_ranked_series/1),
      channels: Enum.map(channels, &Serializer.serialize_ranked_channel/1)
    }
  end

  def search(_params), do: %{query: "", movies: [], series: [], channels: []}

  def suggest(params) do
    query = params["q"] || ""

    if byte_size(query) >= 1 do
      query = Params.search_query(query, 100)
      limit = Params.suggest_limit(params)
      per_bucket = min(limit, 8)
      [movies, series, channels] = search_buckets(query, per_bucket, :timer.seconds(2))

      items =
        (Enum.map(movies, &Serializer.suggest_movie/1) ++
           Enum.map(series, &Serializer.suggest_series/1) ++
           Enum.map(channels, &Serializer.suggest_channel/1))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      %{query: query, items: items}
    else
      %{query: query, items: []}
    end
  end

  def home(params) do
    limit = Params.home_limit(params)

    sections = [
      featured: fn -> featured().featured end,
      trending_movies: fn -> Iptv.list_trending("movie", limit: limit) end,
      recent_movies: fn -> Iptv.list_recent("movie", limit: limit) end,
      top_rated_movies: fn -> Iptv.list_top_rated("movie", limit: limit) end,
      trending_series: fn -> Iptv.list_trending("series", limit: limit) end
    ]

    results = run_sections(sections, :timer.seconds(10))

    %{
      featured: Map.get(results, :featured),
      trending_movies: Serializer.serialize_items("movie", results[:trending_movies] || []),
      recent_movies: Serializer.serialize_items("movie", results[:recent_movies] || []),
      top_rated_movies: Serializer.serialize_items("movie", results[:top_rated_movies] || []),
      trending_series: Serializer.serialize_items("series", results[:trending_series] || [])
    }
  end

  def trending(params), do: shelf(params, &Iptv.list_trending/2)
  def recent(params), do: shelf(params, &Iptv.list_recent/2)
  def top_rated(params), do: shelf(params, &Iptv.list_top_rated/2)

  def movie_stream(id) do
    case Iptv.get_public_movie(id) do
      nil -> {:error, :not_found}
      movie -> {:ok, %{stream_url: StreamUrls.signed_movie_url(movie)}}
    end
  end

  def episode_stream(id) do
    case Iptv.get_public_episode(id) do
      nil -> {:error, :not_found}
      episode -> {:ok, %{stream_url: StreamUrls.signed_episode_url(episode)}}
    end
  end

  def channel_stream(id) do
    case Iptv.get_public_channel(id) do
      nil -> {:error, :not_found}
      channel -> {:ok, %{stream_url: StreamUrls.signed_channel_url(channel)}}
    end
  end

  defp with_global_provider(empty_payload, fun) do
    case Iptv.get_global_provider() do
      nil -> empty_payload
      provider -> fun.(provider)
    end
  end

  defp search_buckets(query, limit, timeout) do
    [
      fn -> Iptv.search_public_movies(query, limit: limit) end,
      fn -> Iptv.search_public_series(query, limit: limit) end,
      fn -> Iptv.search_public_channels(query, limit: limit) end
    ]
    |> Task.async_stream(& &1.(),
      max_concurrency: 3,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, list} -> list
      {:exit, _} -> []
    end)
  end

  defp run_sections(sections, timeout) do
    sections
    |> Task.async_stream(
      fn {key, fun} -> {key, fun.()} end,
      max_concurrency: length(sections),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, value}}, acc -> Map.put(acc, key, value)
      {:exit, _reason}, acc -> acc
    end)
  end

  defp shelf(params, list_fun) do
    limit = Params.shelf_limit(params)
    type = Params.content_type(params["type"])
    items = list_fun.(type, limit: limit)
    %{type: type, items: Serializer.serialize_items(type, items)}
  end

  defp clean_category_name(name) when is_binary(name) do
    name
    |> String.replace(~r/『』/, " - ")
    |> remove_accents()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_category_name(name), do: name

  defp remove_accents(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp safe_fetch(content, fetcher) do
    case fetcher.(content) do
      {:ok, enriched} ->
        enriched

      {:error, reason} ->
        Logger.warning("Catalog enrichment failed: " <> inspect(reason))
        content
    end
  end
end
