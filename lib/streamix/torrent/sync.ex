defmodule Streamix.Torrent.Sync do
  @moduledoc """
  Orchestrator for torrent provider synchronization.

  Iterates the configured `Streamix.Torrent.Sources` modules,
  pages through each source's listing while honouring its declared
  rate limit, and upserts the result into the `movies` +
  `torrent_streams` tables.

  Mirrors `Streamix.Gindex.Sync.sync_provider/1` in shape so the
  worker layer can stay consistent across catalogs.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Movie, Provider}
  alias Streamix.Repo
  alias Streamix.Torrent.{Catalog, Sources, TorrentStream}

  require Logger

  # Hard ceiling on pagination — keeps a runaway source (next_page that
  # never returns nil, server bug, etc.) from wedging an Oban worker
  # past its timeout. YTS currently has ~76k movies / 50 per page
  # (roughly 1,526 pages), so the old 1,000-page cap silently truncated
  # a third of the catalog. Crossing this generous safety valve is an
  # error, never a false success.
  @max_pages 10_000

  @doc """
  Syncs all enabled torrent sources for the given torrent provider.

  Returns `{:ok, stats}` with per-source counts on success, or
  `{:error, reason}` when the provider is not a torrent provider.
  """
  @spec sync_provider(Provider.t()) ::
          {:ok, %{movies_count: non_neg_integer(), sources: [map()]}}
          | {:error, term()}
  def sync_provider(%Provider{provider_type: :torrent} = provider) do
    Logger.info("[Torrent Sync] Starting sync for provider #{provider.id} (#{provider.name})")
    update_status(provider, "syncing")

    results =
      Sources.list()
      |> Enum.map(fn source -> {source, sync_source(provider, source)} end)

    finalize(provider, results)
  end

  def sync_provider(%Provider{} = provider) do
    Logger.warning("[Torrent Sync] Provider #{provider.id} is not a torrent provider")
    {:error, :not_torrent_provider}
  end

  @doc """
  Syncs a single source against the given torrent provider.

  Pages through `source.fetch_listing/1`, sleeping at least
  `source.rate_limit_ms()` between calls, and upserts every listing
  item into `movies` + every magnet into `torrent_streams`.

  Returns `{:ok, stats}` with the totals collected for this source.
  """
  @spec sync_source(Provider.t(), module(), keyword()) ::
          {:ok, %{movies: non_neg_integer(), torrents: non_neg_integer()}}
          | {:error, term()}
  def sync_source(provider, source_module, opts \\ [])

  def sync_source(%Provider{provider_type: :torrent} = provider, source_module, opts)
      when is_atom(source_module) do
    start_page = positive_integer_option(opts, :start_page, 1)
    max_pages = positive_integer_option(opts, :max_pages, @max_pages)
    on_page = Keyword.get(opts, :on_page, fn _progress -> :ok end)

    Logger.info(
      "[Torrent Sync] Source #{source_module.slug()} starting for provider #{provider.id} " <>
        "at page #{start_page}"
    )

    sync_pages(
      provider,
      source_module,
      start_page,
      %{movies: 0, torrents: 0},
      max_pages,
      on_page
    )
  end

  def sync_source(%Provider{} = _provider, _source_module, _opts) do
    {:error, :not_torrent_provider}
  end

  # Pagination loop. Stops when the source signals no `next_page`,
  # the page cap is hit, or fetch_listing returns an error.
  defp sync_pages(_provider, source_module, page, _acc, max_pages, _on_page)
       when page > max_pages do
    reason = %{
      source: source_module.slug(),
      page: page,
      max_pages: max_pages
    }

    Logger.error("[Torrent Sync] page safety limit exceeded: #{inspect(reason)}")
    {:error, {:page_limit_exceeded, reason}}
  end

  defp sync_pages(provider, source_module, page, acc, max_pages, on_page) do
    case source_module.fetch_listing(page: page) do
      {:ok, items, meta} ->
        {movies_count, torrents_count} = upsert_items(provider, source_module, items)

        new_acc = %{
          movies: acc.movies + movies_count,
          torrents: acc.torrents + torrents_count
        }

        continue_sync(
          provider,
          source_module,
          page,
          Map.get(meta, :next_page),
          new_acc,
          max_pages,
          on_page
        )

      {:error, reason} ->
        Logger.error(
          "[Torrent Sync] Source #{source_module.slug()} page #{page} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp continue_sync(
         _provider,
         source_module,
         page,
         nil,
         acc,
         _max_pages,
         on_page
       ) do
    with :ok <- report_page(on_page, page, nil, acc) do
      Logger.info(
        "[Torrent Sync] Source #{source_module.slug()} done at page #{page}: " <>
          "#{acc.movies} movies / #{acc.torrents} torrents"
      )

      {:ok, acc}
    end
  end

  defp continue_sync(
         provider,
         source_module,
         page,
         next_page,
         acc,
         max_pages,
         on_page
       )
       when is_integer(next_page) and next_page > page do
    with :ok <- report_page(on_page, page, next_page, acc) do
      # Intentional Process.sleep: this is an Oban worker process
      # dedicated to this sync — there's no LiveView or GenServer
      # mailbox being starved. Switching to send_after/handle_info
      # would require restructuring sync_pages as a GenServer for
      # no real win.
      Process.sleep(source_module.rate_limit_ms())
      sync_pages(provider, source_module, next_page, acc, max_pages, on_page)
    end
  end

  defp continue_sync(
         _provider,
         source_module,
         page,
         next_page,
         _acc,
         _max_pages,
         _on_page
       ) do
    reason = %{
      source: source_module.slug(),
      page: page,
      next_page: next_page
    }

    Logger.error("[Torrent Sync] invalid pagination cursor: #{inspect(reason)}")
    {:error, {:invalid_pagination, reason}}
  end

  defp report_page(on_page, page, next_page, acc) when is_function(on_page, 1) do
    case on_page.(Map.merge(acc, %{page: page, next_page: next_page})) do
      :ok -> :ok
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
      other -> {:error, {:checkpoint_failed, {:unexpected_result, other}}}
    end
  rescue
    error -> {:error, {:checkpoint_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:checkpoint_failed, {:exit, reason}}}
  end

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      invalid ->
        raise ArgumentError, "expected #{inspect(key)} to be positive, got: #{inspect(invalid)}"
    end
  end

  # Persists one page of listing items.
  #
  # Returns `{movies_inserted_or_updated, torrents_inserted_or_updated}`.
  defp upsert_items(provider, source_module, items) when is_list(items) do
    source_slug = source_module.slug()
    now = DateTime.utc_now(:second)

    items
    |> Enum.reject(&blank_title?/1)
    |> Enum.reduce({0, 0}, fn item, {movies, torrents} ->
      case upsert_item(provider, source_slug, item, now) do
        {:ok, torrent_count} -> {movies + 1, torrents + torrent_count}
        {:error, _} -> {movies, torrents}
      end
    end)
  end

  # Some YTS rows leak through with an empty title (movies in late
  # scrub state on the upstream). Movie.changeset enforces
  # validate_required([:name, …]) so the changeset blows up inside
  # upsert_movie/3, gets caught by the rescue, and the item is
  # silently dropped. Catching it at the boundary is cheaper than
  # raising/rescuing per row and keeps the error log clean.
  defp blank_title?(item) do
    case Map.get(item, :title) || Map.get(item, "title") do
      nil -> true
      title when is_binary(title) -> String.trim(title) == ""
      _ -> true
    end
  end

  defp upsert_item(provider, source_slug, item, now) do
    Repo.transaction(fn ->
      movie = upsert_movie(provider, item, now)
      torrent_count = upsert_torrents(movie, source_slug, item.torrents || [])
      torrent_count
    end)
  rescue
    e ->
      Logger.error(
        "[Torrent Sync] Failed to upsert item #{inspect(item[:external_id])}: #{inspect(e)}"
      )

      {:error, e}
  end

  # Upserts the parent movie row.
  #
  # Torrent movies don't carry an Xtream stream_id; we synthesize one
  # from the source's external_id via `:erlang.phash2/1` so the
  # `(provider_id, stream_id)` unique constraint stays happy and we
  # can't collide with xtream-sourced movies on the same provider
  # (which there shouldn't be, since the torrent provider is its own
  # row, but belt-and-suspenders).
  defp upsert_movie(provider, item, now) do
    stream_id = synthesize_stream_id(item.external_id)

    case Repo.one(
           from m in Movie,
             where: m.provider_id == ^provider.id and m.stream_id == ^stream_id
         ) do
      nil ->
        catalog_item =
          %CatalogItem{}
          |> CatalogItem.changeset(%{content_type: "movie", provider_id: provider.id})
          |> Repo.insert!()

        %Movie{}
        |> Movie.changeset(movie_attrs(item, provider.id, stream_id, catalog_item.id, now))
        |> Repo.insert!()

      existing ->
        existing
        |> Movie.changeset(
          movie_attrs(item, provider.id, stream_id, existing.catalog_item_id, now)
        )
        |> Repo.update!()
    end
  end

  defp movie_attrs(item, provider_id, stream_id, catalog_item_id, now) do
    %{
      provider_id: provider_id,
      catalog_item_id: catalog_item_id,
      stream_id: stream_id,
      name: item.title,
      title: item.title,
      year: Map.get(item, :year),
      stream_icon: Map.get(item, :poster_url),
      rating: cast_rating(Map.get(item, :rating)),
      plot: Map.get(item, :plot),
      tmdb_id: Map.get(item, :tmdb_id),
      imdb_id: Map.get(item, :imdb_id),
      duration_secs: runtime_to_seconds(Map.get(item, :runtime_minutes)),
      updated_at: now
    }
  end

  defp upsert_torrents(_movie, _source_slug, []), do: 0

  defp upsert_torrents(movie, source_slug, torrents) do
    now = DateTime.utc_now(:second)

    entries =
      torrents
      |> Enum.map(&torrent_entry(&1, movie.id, source_slug, now))
      |> Enum.reject(&is_nil/1)

    if entries == [] do
      0
    else
      {count, _} =
        Repo.insert_all(TorrentStream, entries,
          on_conflict:
            {:replace,
             [
               :magnet_uri,
               :quality,
               :codec,
               :audio_track,
               :container,
               :size_bytes,
               :seeders,
               :leechers,
               :seeders_updated_at,
               :updated_at
             ]},
          conflict_target: :info_hash
        )

      count
    end
  end

  defp torrent_entry(magnet, movie_id, source_slug, now) do
    info_hash = magnet[:info_hash] || ""

    if valid_info_hash?(info_hash) do
      %{
        info_hash: String.downcase(info_hash),
        magnet_uri: magnet.magnet_uri,
        source_slug: magnet[:source_slug] || source_slug,
        quality: magnet[:quality],
        codec: magnet[:codec],
        audio_track: magnet[:audio_track],
        container: magnet[:container],
        size_bytes: magnet[:size_bytes],
        seeders: magnet[:seeders] || 0,
        leechers: magnet[:leechers] || 0,
        seeders_updated_at: now,
        movie_id: movie_id,
        episode_id: nil,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp valid_info_hash?(hash) when is_binary(hash) do
    Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash)
  end

  defp valid_info_hash?(_), do: false

  defp synthesize_stream_id(external_id) when is_binary(external_id) do
    :erlang.phash2(external_id)
  end

  defp synthesize_stream_id(external_id), do: :erlang.phash2(external_id)

  defp cast_rating(nil), do: nil

  defp cast_rating(value) when is_number(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp cast_rating(_), do: nil

  defp runtime_to_seconds(nil), do: nil
  defp runtime_to_seconds(minutes) when is_integer(minutes) and minutes > 0, do: minutes * 60
  defp runtime_to_seconds(_), do: nil

  defp finalize(provider, results) do
    sources_stats =
      Enum.map(results, fn
        {module, {:ok, stats}} ->
          %{slug: module.slug(), status: :ok, movies: stats.movies, torrents: stats.torrents}

        {module, {:error, reason}} ->
          %{slug: module.slug(), status: :error, reason: reason}
      end)

    successful = Enum.filter(sources_stats, &(&1.status == :ok))
    movies_total = Enum.reduce(successful, 0, &(&1.movies + &2))

    has_failures? = Enum.any?(sources_stats, &(&1.status == :error))

    sync_status = if has_failures? and successful == [], do: "failed", else: "completed"

    now = DateTime.utc_now(:second)

    provider
    |> Provider.sync_changeset(%{
      sync_status: sync_status,
      movies_count: movies_total,
      vod_synced_at: now
    })
    |> Repo.update()

    Logger.info(
      "[Torrent Sync] Provider #{provider.id} finalized: #{movies_total} movies " <>
        "across #{length(successful)}/#{length(sources_stats)} sources"
    )

    {:ok, %{movies_count: movies_total, sources: sources_stats}}
  end

  defp update_status(provider, status) do
    provider
    |> Provider.sync_changeset(%{sync_status: status})
    |> Repo.update()
  end

  @doc """
  Recomputes the provider's catalog counter from the database and marks
  it synced.

  `finalize/2` only runs on the full `sync_provider/1` path. Production
  fans out one `SyncSourceWorker` per source instead, and those never
  touched the provider row — so `movies_count` stayed at 0 and
  `sync_status` at whatever a prior full run (or the initial bootstrap)
  left behind, even with tens of thousands of rows ingested. Each
  source worker calls this on success so the counter reflects the real
  catalog regardless of which path or how many sources ran.

  Counts from `movies` directly (source of truth) rather than summing
  per-source stats, which can drift across partial/parallel runs.
  """
  @spec refresh_provider_counts(Provider.t(), keyword()) ::
          {:ok, Provider.t()} | {:error, term()}
  def refresh_provider_counts(provider, opts \\ [])

  def refresh_provider_counts(%Provider{provider_type: :torrent} = provider, opts) do
    with :ok <- Catalog.refresh_stats(provider.id) do
      movies_count =
        Repo.aggregate(from(m in Movie, where: m.provider_id == ^provider.id), :count)

      now = DateTime.utc_now(:second)
      sync_status = Keyword.get(opts, :sync_status, "completed")

      provider
      |> Provider.sync_changeset(%{
        sync_status: sync_status,
        movies_count: movies_count,
        vod_synced_at: now
      })
      |> Repo.update()
    end
  end

  def refresh_provider_counts(%Provider{}, _opts), do: {:error, :not_torrent_provider}
end
