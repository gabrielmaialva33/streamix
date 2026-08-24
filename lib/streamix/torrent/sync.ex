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

  alias Streamix.Iptv
  alias Streamix.Providers
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
  @spec sync_provider(term()) ::
          {:ok, %{movies_count: non_neg_integer(), sources: [map()]}}
          | {:error, term()}
  def sync_provider(provider) do
    case Providers.torrent_sync_source(provider) do
      {:ok, source} ->
        start_provider_sync(source)

      {:error, :not_torrent_provider} = error ->
        Logger.warning(
          "[Torrent Sync] Provider #{provider_id(provider)} is not a torrent provider"
        )

        error
    end
  end

  defp start_provider_sync(source) do
    Logger.info(
      "[Torrent Sync] Starting sync for provider #{source.provider_id} (#{source.name})"
    )

    case update_status(source, "syncing") do
      :ok ->
        results =
          Sources.list()
          |> Enum.map(fn source_module ->
            {source_module, do_sync_source(source, source_module, [])}
          end)

        finalize(source, results)

      {:error, reason} ->
        provider_state_error("start", reason)
    end
  end

  @doc """
  Syncs a single source against the given torrent provider.

  Pages through `source.fetch_listing/1`, sleeping at least
  `source.rate_limit_ms()` between calls, and upserts every listing
  item into `movies` + every magnet into `torrent_streams`.

  Returns `{:ok, stats}` with the totals collected for this source.
  """
  @spec sync_source(term(), module(), keyword()) ::
          {:ok, %{movies: non_neg_integer(), torrents: non_neg_integer()}}
          | {:error, term()}
  def sync_source(provider, source_module, opts \\ [])

  def sync_source(provider, source_module, opts) when is_atom(source_module) do
    with {:ok, source} <- Providers.torrent_sync_source(provider) do
      do_sync_source(source, source_module, opts)
    end
  end

  def sync_source(provider, _source_module, _opts) do
    case Providers.torrent_sync_source(provider) do
      {:ok, _source} -> {:error, :invalid_source}
      {:error, :not_torrent_provider} = error -> error
    end
  end

  defp do_sync_source(source, source_module, opts) do
    start_page = positive_integer_option(opts, :start_page, 1)
    max_pages = positive_integer_option(opts, :max_pages, @max_pages)
    on_page = Keyword.get(opts, :on_page, fn _progress -> :ok end)

    Logger.info(
      "[Torrent Sync] Source #{source_module.slug()} starting for provider #{source.provider_id} " <>
        "at page #{start_page}"
    )

    sync_pages(
      source,
      source_module,
      start_page,
      %{movies: 0, torrents: 0},
      max_pages,
      on_page
    )
  end

  # Pagination loop. Stops when the source signals no `next_page`,
  # the page cap is hit, or fetch_listing returns an error.
  defp sync_pages(_source, source_module, page, _acc, max_pages, _on_page)
       when page > max_pages do
    reason = %{
      source: source_module.slug(),
      page: page,
      max_pages: max_pages
    }

    Logger.error("[Torrent Sync] page safety limit exceeded: #{inspect(reason)}")
    {:error, {:page_limit_exceeded, reason}}
  end

  defp sync_pages(source, source_module, page, acc, max_pages, on_page) do
    case source_module.fetch_listing(page: page) do
      {:ok, items, meta} ->
        case upsert_items(source, source_module, items) do
          {:ok, {movies_count, torrents_count}} ->
            new_acc = %{
              movies: acc.movies + movies_count,
              torrents: acc.torrents + torrents_count
            }

            continue_sync(
              source,
              source_module,
              page,
              Map.get(meta, :next_page),
              new_acc,
              max_pages,
              on_page
            )

          {:error, reason} ->
            Logger.error(
              "[Torrent Sync] Source #{source_module.slug()} page #{page} persistence failed: " <>
                inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "[Torrent Sync] Source #{source_module.slug()} page #{page} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp continue_sync(
         _source,
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
         source,
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
      sync_pages(source, source_module, next_page, acc, max_pages, on_page)
    end
  end

  defp continue_sync(
         _source,
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
  # Returns `{:ok, {movies_inserted_or_updated, torrents_inserted_or_updated}}`.
  defp upsert_items(source, source_module, items) when is_list(items) do
    source_slug = source_module.slug()

    items
    |> Enum.reject(&blank_title?/1)
    |> Enum.reduce_while({:ok, {0, 0}}, fn item, {:ok, {movies, torrents}} ->
      case upsert_item(source, source_slug, item) do
        {:ok, torrent_count} ->
          {:cont, {:ok, {movies + 1, torrents + torrent_count}}}

        {:error, reason} ->
          external_id = Map.get(item, :external_id) || Map.get(item, "external_id")
          {:halt, {:error, {:item_upsert_failed, external_id, reason}}}
      end
    end)
  end

  # Some YTS rows leak through with an empty title (movies in late
  # scrub state on the upstream). Catching it at the source boundary is
  # cheaper than building a changeset for a row we know cannot be stored.
  defp blank_title?(item) do
    case Map.get(item, :title) || Map.get(item, "title") do
      nil -> true
      title when is_binary(title) -> String.trim(title) == ""
      _ -> true
    end
  end

  defp upsert_item(source, source_slug, item) do
    Repo.transact(fn ->
      with {:ok, movie_id} <-
             Iptv.upsert_torrent_movie(
               source.provider_id,
               movie_attrs(item, synthesize_stream_id(item.external_id))
             ) do
        {:ok, upsert_torrents(movie_id, source_slug, item.torrents || [])}
      end
    end)
  rescue
    error ->
      Logger.error(
        "[Torrent Sync] Failed to upsert item #{inspect(item[:external_id])}:\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, {:persistence_exception, Exception.message(error)}}
  end

  # Upserts the parent movie row.
  #
  # Torrent movies don't carry an Xtream stream_id; we preserve the existing
  # provider-local identifier derived from each source's external_id.
  defp movie_attrs(item, stream_id) do
    %{
      stream_id: stream_id,
      name: item.title,
      title: item.title,
      year: Map.get(item, :year),
      stream_icon: Map.get(item, :poster_url),
      rating: cast_rating(Map.get(item, :rating)),
      plot: Map.get(item, :plot),
      tmdb_id: Map.get(item, :tmdb_id),
      imdb_id: Map.get(item, :imdb_id),
      duration_secs: runtime_to_seconds(Map.get(item, :runtime_minutes))
    }
  end

  defp upsert_torrents(_movie_id, _source_slug, []), do: 0

  defp upsert_torrents(movie_id, source_slug, torrents) do
    now = DateTime.utc_now(:second)

    entries =
      torrents
      |> Enum.map(&torrent_entry(&1, movie_id, source_slug, now))
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

  defp finalize(source, results) do
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

    sync_status =
      cond do
        not has_failures? -> "completed"
        successful == [] -> "failed"
        true -> "partial"
      end

    now = DateTime.utc_now(:second)
    attrs = %{sync_status: sync_status, movies_count: movies_total, vod_synced_at: now}

    case Providers.update_torrent_sync(source.provider_id, attrs) do
      :ok ->
        Logger.info(
          "[Torrent Sync] Provider #{source.provider_id} finalized: #{movies_total} movies " <>
            "across #{length(successful)}/#{length(sources_stats)} sources"
        )

        {:ok, %{movies_count: movies_total, sources: sources_stats}}

      {:error, reason} ->
        provider_state_error("finish", reason)
    end
  end

  defp update_status(source, status),
    do: Providers.update_torrent_sync(source.provider_id, %{sync_status: status})

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
  @spec refresh_provider_counts(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_provider_counts(provider, opts \\ [])

  def refresh_provider_counts(provider, opts) do
    with {:ok, source} <- Providers.torrent_sync_source(provider),
         :ok <- Catalog.refresh_stats(source.provider_id) do
      movies_count = Iptv.count_torrent_movies(source.provider_id, show_adult: true)
      now = DateTime.utc_now(:second)
      sync_status = Keyword.get(opts, :sync_status, "completed")
      attrs = %{sync_status: sync_status, movies_count: movies_count, vod_synced_at: now}

      case Providers.update_torrent_sync(source.provider_id, attrs) do
        :ok -> {:ok, Map.put(attrs, :provider_id, source.provider_id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp provider_state_error(stage, reason) do
    Logger.error("[Torrent Sync] Could not #{stage} provider state update: #{inspect(reason)}")
    {:error, {:provider_state_update_failed, reason}}
  end

  defp provider_id(%{id: id}), do: id
  defp provider_id(_provider), do: "unknown"
end
