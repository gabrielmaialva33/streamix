defmodule StreamixWeb.Catalog.Api do
  @moduledoc """
  Builds response payloads for the public Catalog API.
  """

  require Logger

  alias Streamix.Iptv
  alias StreamixWeb.Catalog.Pagination
  alias StreamixWeb.Catalog.Params
  alias StreamixWeb.Catalog.Serializer
  alias StreamixWeb.Catalog.StreamUrls

  def featured(params \\ %{}) do
    provider_opts = Params.provider_opts(params)

    %{
      data: Iptv.get_featured_content(provider_opts) |> Serializer.serialize_featured(),
      meta: %{
        catalog_counts: Iptv.get_public_stats(provider_opts),
        filters: provider_filter_meta(provider_opts)
      }
    }
  end

  def movies(params) do
    opts = Params.movies_opts(params)
    movies = Iptv.list_public_catalog_movies(opts)
    total = Iptv.count_public_catalog_movies(opts)

    page(Enum.map(movies, &Serializer.serialize_movie/1), total, opts)
  end

  def movie_detail(id) do
    case Iptv.get_public_movie(id) do
      nil ->
        {:error, :not_found}

      movie ->
        {:ok,
         %{
           data:
             movie |> safe_fetch(&Iptv.fetch_movie_info/1) |> Serializer.serialize_movie_detail()
         }}
    end
  end

  def series(params) do
    opts = Params.series_opts(params)
    series_list = Iptv.list_public_catalog_series(opts)
    total = Iptv.count_public_catalog_series(opts)

    page(Enum.map(series_list, &Serializer.serialize_series/1), total, opts)
  end

  def series_detail(id) do
    case Iptv.get_public_series(id) do
      nil ->
        {:error, :not_found}

      series ->
        series = Iptv.get_series_with_sync!(series.id)
        {:ok, %{data: Serializer.serialize_series_detail(series)}}
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
         %{
           data:
             episode
             |> safe_fetch(&Iptv.fetch_episode_info/1)
             |> Serializer.serialize_episode_detail()
         }}
    end
  end

  def channels(params) do
    opts = Params.channels_opts(params)
    channels = Iptv.list_public_catalog_channels(opts)
    total = Iptv.count_public_catalog_channels(opts)

    page(Enum.map(channels, &Serializer.serialize_channel/1), total, opts)
  end

  def channel_detail(id) do
    case Iptv.get_public_channel(id) do
      nil -> {:error, :not_found}
      channel -> {:ok, %{data: Serializer.serialize_channel_detail(channel)}}
    end
  end

  def categories(params) do
    opts = Params.categories_opts(params)

    categories =
      opts
      |> Iptv.list_public_categories()
      |> Enum.map(fn category ->
        %{
          id: category.id,
          name: clean_category_name(category.name),
          type: category.type,
          provider: Serializer.serialize_provider_ref(category.provider)
        }
      end)

    %{
      data: categories,
      meta: %{total: length(categories), filters: category_filters(opts)}
    }
  end

  def providers do
    providers = Iptv.list_public_providers()

    %{
      data: Enum.map(providers, &Serializer.serialize_provider/1),
      meta: %{total: length(providers)}
    }
  end

  def search(%{"q" => raw_query} = params) when is_binary(raw_query) do
    query = Params.search_query(raw_query, 200)
    provider_opts = Params.provider_opts(params)

    if String.length(query) >= 2 do
      limit = Params.search_limit(params)

      [movies, series, channels] =
        search_buckets(query, limit, provider_opts, :timer.seconds(5))

      %{
        data: %{
          movies: Enum.map(movies, &Serializer.serialize_ranked_movie/1),
          series: Enum.map(series, &Serializer.serialize_ranked_series/1),
          channels: Enum.map(channels, &Serializer.serialize_ranked_channel/1)
        },
        meta: %{
          query: query,
          limit_per_type: limit,
          filters: provider_filter_meta(provider_opts)
        }
      }
    else
      empty_search(query, Params.search_limit(params), provider_opts)
    end
  end

  def search(params) do
    empty_search("", Params.search_limit(params), Params.provider_opts(params))
  end

  def suggest(params) do
    query = Params.search_query(params["q"] || "", 100)
    provider_opts = Params.provider_opts(params)

    if String.length(query) >= 1 do
      limit = Params.suggest_limit(params)
      per_bucket = min(limit, 8)

      [movies, series, channels] =
        search_buckets(query, per_bucket, provider_opts, :timer.seconds(2))

      items =
        (Enum.map(movies, &Serializer.suggest_movie/1) ++
           Enum.map(series, &Serializer.suggest_series/1) ++
           Enum.map(channels, &Serializer.suggest_channel/1))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      %{
        data: items,
        meta: %{query: query, limit: limit, filters: provider_filter_meta(provider_opts)}
      }
    else
      %{
        data: [],
        meta: %{
          query: query,
          limit: Params.suggest_limit(params),
          filters: provider_filter_meta(provider_opts)
        }
      }
    end
  end

  def home(params) do
    limit = Params.home_limit(params)
    provider_opts = Params.provider_opts(params)
    section_opts = Keyword.put(provider_opts, :limit, limit)

    sections = [
      featured: fn ->
        provider_opts
        |> Iptv.get_featured_content()
        |> Serializer.serialize_featured()
      end,
      trending_movies: fn -> Iptv.list_trending("movie", section_opts) end,
      recent_movies: fn -> Iptv.list_recent("movie", section_opts) end,
      top_rated_movies: fn -> Iptv.list_top_rated("movie", section_opts) end,
      trending_series: fn -> Iptv.list_trending("series", section_opts) end
    ]

    results = run_sections(sections, :timer.seconds(10))

    %{
      data: %{
        featured: Map.get(results, :featured),
        trending_movies: Serializer.serialize_items("movie", results[:trending_movies] || []),
        recent_movies: Serializer.serialize_items("movie", results[:recent_movies] || []),
        top_rated_movies: Serializer.serialize_items("movie", results[:top_rated_movies] || []),
        trending_series: Serializer.serialize_items("series", results[:trending_series] || [])
      },
      meta: %{
        limit_per_section: limit,
        filters: provider_filter_meta(provider_opts)
      }
    }
  end

  def trending(params), do: shelf(params, &Iptv.list_trending/2)
  def recent(params), do: shelf(params, &Iptv.list_recent/2)
  def top_rated(params), do: shelf(params, &Iptv.list_top_rated/2)

  def movie_stream(id) do
    case Iptv.get_public_movie(id) do
      nil -> {:error, :not_found}
      movie -> {:ok, %{data: %{stream_url: StreamUrls.signed_movie_url(movie)}}}
    end
  end

  def episode_stream(id) do
    case Iptv.get_public_episode(id) do
      nil -> {:error, :not_found}
      episode -> {:ok, %{data: %{stream_url: StreamUrls.signed_episode_url(episode)}}}
    end
  end

  def channel_stream(id) do
    case Iptv.get_public_channel(id) do
      nil -> {:error, :not_found}
      channel -> {:ok, %{data: %{stream_url: StreamUrls.signed_channel_url(channel)}}}
    end
  end

  defp search_buckets(query, limit, provider_opts, timeout) do
    opts = Keyword.put(provider_opts, :limit, limit)

    [
      fn -> Iptv.search_public_movies(query, opts) end,
      fn -> Iptv.search_public_series(query, opts) end,
      fn -> Iptv.search_public_channels(query, opts) end
    ]
    |> Task.async_stream(& &1.(),
      max_concurrency: 3,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, list} ->
        list

      {:exit, reason} ->
        Logger.warning("Catalog search bucket failed", reason_kind: reason_kind(reason))
        []
    end)
  end

  defp empty_search(query, limit, provider_opts) do
    %{
      data: %{movies: [], series: [], channels: []},
      meta: %{
        query: query,
        limit_per_type: limit,
        filters: provider_filter_meta(provider_opts)
      }
    }
  end

  defp reason_kind(reason) when is_atom(reason), do: reason
  defp reason_kind({tag, _}) when is_atom(tag), do: tag
  defp reason_kind(_reason), do: :other

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
      {:ok, {key, value}}, acc ->
        Map.put(acc, key, value)

      {:exit, reason}, acc ->
        Logger.warning("Catalog home section failed", reason_kind: reason_kind(reason))
        acc
    end)
  end

  defp shelf(params, list_fun) do
    limit = Params.shelf_limit(params)
    type = Params.content_type(params["type"])
    provider_opts = Params.provider_opts(params)
    items = list_fun.(type, Keyword.put(provider_opts, :limit, limit))

    %{
      data: Serializer.serialize_items(type, items),
      meta: %{type: type, limit: limit, filters: provider_filter_meta(provider_opts)}
    }
  end

  defp page(data, total, opts) do
    limit = Keyword.fetch!(opts, :limit)
    offset = Keyword.fetch!(opts, :offset)

    %{
      data: data,
      meta: %{
        pagination: Pagination.metadata(length(data), total, limit, offset),
        filters: content_filters(opts)
      }
    }
  end

  defp content_filters(opts) do
    %{
      provider_id: opts[:provider_id],
      provider_type: provider_type_name(opts[:provider_type]),
      category_id: opts[:category_id],
      search: blank_to_nil(opts[:search]),
      sort: opts[:sort]
    }
  end

  defp category_filters(opts) do
    %{
      provider_id: opts[:provider_id],
      provider_type: provider_type_name(opts[:provider_type]),
      type: opts[:type]
    }
  end

  defp provider_filter_meta(opts) do
    %{
      provider_id: opts[:provider_id],
      provider_type: provider_type_name(opts[:provider_type])
    }
  end

  defp provider_type_name(nil), do: nil

  defp provider_type_name(provider_type) when is_atom(provider_type),
    do: Atom.to_string(provider_type)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
