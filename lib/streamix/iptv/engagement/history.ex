defmodule Streamix.Iptv.History do
  @moduledoc """
  Watch history and playback progress, sealed with the user's library key.

  `watch_progress` rows carry no readable reference to content (see
  `Streamix.Iptv.WatchProgress`), so the database cannot join them to the
  catalog. Listings open the user's rows in memory, then resolve the catalog
  items they point at; the progress bar of a given card goes through the HMAC
  blind index instead of a scan.

  Every function takes the caller's unlocked `Streamix.Library.Key`, which
  also identifies the user.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.{CatalogItem, CatalogItemRedirect, Episode, Season, WatchProgress}
  alias Streamix.Iptv.ContentRef
  alias Streamix.Iptv.Engagement.ContentPolicy
  alias Streamix.Library.{Cipher, Key}
  alias Streamix.Repo

  @context "watch_progress"
  @digest_namespace "watch_progress:catalog_item"
  # Writes of one user are serialized: an update reads, decrypts and re-seals
  # the row, and two interleaved ones would drop each other's changes.
  @write_lock_namespace 0x11B_4A27
  @catalog_preloads [:movie, :series, :live_channel, episode: :season]
  @progress_types %{progress_seconds: :integer, duration_seconds: :integer, completed: :boolean}

  @doc """
  Lists watch progress for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 50)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "episode", "live_channel")
  """
  @spec list(Key.t(), keyword()) :: [map()]
  def list(%Key{} = key, opts \\ []) do
    key
    |> visible_cards(opts)
    |> Enum.map(&build_history_entry/1)
  end

  @doc """
  Lists lightweight watch history cards for home surfaces without generic content preloads.
  """
  @spec list_home(Key.t(), keyword()) :: [map()]
  def list_home(%Key{} = key, opts \\ []) do
    key
    |> visible_cards(opts)
    |> Enum.map(&build_home_card/1)
  end

  @doc """
  Lists lightweight watch history entries for analytics without catalog preloads.
  """
  @spec list_for_analytics(Key.t(), keyword()) :: [map()]
  def list_for_analytics(%Key{} = key, opts \\ []) do
    key
    |> visible_cards(opts)
    |> Enum.map(fn card ->
      %{
        content_type: card.content_type,
        content_id: content_id(card),
        series_id: if(card.content_type == "episode", do: card.episode_series_id),
        progress_seconds: card.progress_seconds,
        duration_seconds: card.duration_seconds,
        completed: card.completed,
        watched_at: card.watched_at
      }
    end)
  end

  @doc """
  Counts watch progress grouped by content type for a user.
  Returns a map like %{"movie" => 10, "episode" => 15, "live_channel" => 3}
  """
  @spec count_by_type(Key.t(), keyword()) :: %{String.t() => integer()}
  def count_by_type(%Key{} = key, opts \\ []) do
    entries = open_all(key)

    visible =
      visible_catalog_item_ids(
        key,
        Enum.map(entries, & &1.catalog_item_id),
        Keyword.get(opts, :show_adult, false)
      )

    entries
    |> Enum.filter(&MapSet.member?(visible, &1.catalog_item_id))
    |> Enum.frequencies_by(& &1.content_type)
  end

  @doc """
  Upserts a watch progress entry. If one exists for this user + catalog_item,
  it updates; otherwise inserts.
  """
  @spec add(Key.t(), String.t(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(%Key{} = key, content_type, content_id, attrs \\ %{}) do
    with {:ok, normalized_id} <- ContentRef.normalize_id(content_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(content_type, normalized_id),
         true <- ContentPolicy.visible_catalog_item?(key.user_id, catalog_item_id) do
      upsert_progress(key, catalog_item_id, attrs)
    else
      {:error, :invalid_content_id} -> {:error, error_changeset(:content_id, "is invalid")}
      {:error, :invalid_content_type} -> {:error, error_changeset(:content_type, "is invalid")}
      {:error, :not_found} -> {:error, error_changeset(:content_id, "content not found")}
      false -> {:error, error_changeset(:content_id, "content not found")}
    end
  end

  @doc """
  Adds a watch progress entry from a map of attributes (convenience for PlayerLive).
  """
  @spec add(Key.t(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(%Key{} = key, attrs) when is_map(attrs) do
    add(
      key,
      attrs[:content_type] || attrs["content_type"],
      attrs[:content_id] || attrs["content_id"],
      attrs
    )
  end

  @doc """
  Updates viewing progress for content.
  Marks as completed if progress reaches 90% of duration.
  """
  @spec update_progress(Key.t(), String.t(), integer(), integer(), integer() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_progress(
        %Key{} = key,
        content_type,
        content_id,
        progress_seconds,
        duration_seconds \\ nil
      ) do
    attrs = %{progress_seconds: progress_seconds}

    attrs =
      if duration_seconds, do: Map.put(attrs, :duration_seconds, duration_seconds), else: attrs

    attrs =
      if duration_seconds && progress_seconds >= duration_seconds * 0.9 do
        Map.put(attrs, :completed, true)
      else
        attrs
      end

    add(key, content_type, content_id, attrs)
  end

  @doc """
  Updates watch progress from PlayerLive events.
  Handles nil duration for live streams.
  """
  @spec update_watch_progress(Key.t(), String.t(), integer(), number() | nil, number() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_watch_progress(%Key{} = key, content_type, content_id, current_time, duration) do
    duration_rounded = if duration, do: round(duration), else: nil
    update_progress(key, content_type, content_id, round(current_time || 0), duration_rounded)
  end

  @doc """
  Updates only the duration_seconds field.
  """
  @spec update_watch_time(Key.t(), String.t(), integer(), number()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_watch_time(%Key{} = key, content_type, content_id, duration_seconds) do
    add(key, content_type, content_id, %{duration_seconds: round(duration_seconds)})
  end

  @doc """
  Removes a single watch progress entry by its ID.
  """
  @spec remove(Key.t(), integer()) :: {integer(), nil}
  def remove(%Key{user_id: user_id}, entry_id) do
    WatchProgress
    |> where(user_id: ^user_id, id: ^entry_id)
    |> Repo.delete_all()
  end

  @doc """
  Clears all watch progress for a user.
  Returns {:ok, count} with number of deleted entries.
  """
  @spec clear(Key.t() | integer()) :: {:ok, integer()}
  def clear(%Key{user_id: user_id}), do: clear(user_id)

  def clear(user_id) when is_integer(user_id) do
    {count, _} =
      WatchProgress
      |> where(user_id: ^user_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns a map of series_id => progress (0.0..1.0) based on the latest watched episode.
  Used for showing progress bars on series cards.
  """
  @spec get_series_progress_map(Key.t(), [integer()]) :: %{integer() => float()}
  def get_series_progress_map(_key, []), do: %{}

  def get_series_progress_map(%Key{} = key, series_ids) do
    key
    |> open_by_series(series_ids)
    |> Enum.filter(&(positive?(&1.duration_seconds) and positive?(&1.progress_seconds)))
    |> latest_per_series()
    |> Map.new(fn {series_id, entry} ->
      {series_id, Float.round(entry.progress_seconds / entry.duration_seconds, 2)}
    end)
  end

  @doc "Latest watched episode per requested series, preserving each copy's progress."
  def latest_series_progress(_key, []), do: %{}
  def latest_series_progress(nil, _series_ids), do: %{}

  def latest_series_progress(%Key{} = key, series_ids) do
    latest =
      key
      |> open_by_series(series_ids)
      |> Enum.filter(&(positive?(&1.progress_seconds) and not is_nil(&1.last_watched_at)))
      |> latest_per_series()

    episode_ids =
      latest
      |> Enum.map(fn {_series_id, entry} -> entry.catalog_item_id end)
      |> episode_ids_by_catalog_item()

    Enum.reduce(latest, %{}, fn {series_id, entry}, acc ->
      case Map.fetch(episode_ids, entry.catalog_item_id) do
        {:ok, episode_id} ->
          Map.put(acc, series_id, %{
            episode_id: episode_id,
            watched_at: entry.last_watched_at,
            progress_id: entry.id,
            completed: entry.completed
          })

        :error ->
          acc
      end
    end)
  end

  @doc """
  Returns a map of content_id => progress (0.0..1.0) for the given content IDs.
  Used for showing progress bars on content cards.
  """
  @spec get_progress_map(Key.t(), String.t(), [integer()]) :: %{integer() => float()}
  def get_progress_map(_key, _content_type, []), do: %{}

  def get_progress_map(%Key{} = key, content_type, content_ids) do
    case content_schema(content_type) do
      nil -> %{}
      schema -> do_get_progress_map(key, schema, content_ids)
    end
  end

  defp do_get_progress_map(key, schema, content_ids) do
    content_by_digest =
      from(content in schema,
        where: content.id in ^content_ids,
        select: {content.id, content.catalog_item_id}
      )
      |> Repo.all()
      |> Map.new(fn {content_id, catalog_item_id} ->
        {item_digest(key, catalog_item_id), content_id}
      end)

    key
    |> open_where(dynamic([progress], progress.item_digest in ^Map.keys(content_by_digest)))
    |> Enum.filter(&(positive?(&1.duration_seconds) and positive?(&1.progress_seconds)))
    |> Map.new(fn entry ->
      {Map.fetch!(content_by_digest, entry.item_digest),
       Float.round(entry.progress_seconds / entry.duration_seconds, 2)}
    end)
  end

  @doc false
  # The sealed row for `facts`, shared with the one-off legacy import.
  @spec sealed_row(Key.t(), map()) :: map()
  def sealed_row(%Key{} = key, facts) do
    %{
      user_id: key.user_id,
      item_digest: item_digest(key, facts.catalog_item_id),
      sealed:
        Cipher.seal_map(key, @context, %{
          "catalog_item_id" => facts.catalog_item_id,
          "content_type" => facts.content_type,
          "series_id" => facts.series_id,
          "progress_seconds" => facts.progress_seconds,
          "duration_seconds" => facts.duration_seconds,
          "completed" => facts.completed,
          "last_watched_at" => facts.last_watched_at && DateTime.to_iso8601(facts.last_watched_at)
        })
    }
  end

  # --- Private ---

  defp upsert_progress(key, catalog_item_id, attrs) do
    with {:ok, catalog_item} <- fetch_catalog_item(catalog_item_id) do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [write_lock_key(key)])
        write_progress(key, catalog_item, attrs)
      end)
    end
  end

  defp write_progress(key, catalog_item, attrs) do
    digest = item_digest(key, catalog_item.id)

    previous =
      case open_where(key, dynamic([progress], progress.item_digest == ^digest)) do
        [entry] -> entry
        [] -> nil
      end

    with {:ok, progress} <- cast_progress(previous, attrs) do
      facts =
        Map.merge(progress, %{
          catalog_item_id: catalog_item.id,
          content_type: catalog_item.content_type,
          series_id: series_id(catalog_item),
          last_watched_at: DateTime.utc_now(:second)
        })

      %WatchProgress{}
      |> Changeset.change(sealed_row(key, facts))
      |> Repo.insert(
        on_conflict: {:replace, [:sealed]},
        conflict_target: [:user_id, :item_digest],
        returning: [:id]
      )
      |> case do
        {:ok, stored} -> {:ok, decorate(stored, facts, catalog_item)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp write_lock_key(%Key{user_id: user_id}),
    do: Bitwise.bor(Bitwise.bsl(@write_lock_namespace, 32), user_id)

  defp cast_progress(previous, attrs) do
    base = %{
      progress_seconds: (previous && previous.progress_seconds) || 0,
      duration_seconds: previous && previous.duration_seconds,
      completed: (previous && previous.completed) || false
    }

    {base, @progress_types}
    |> Changeset.cast(permitted_progress(attrs), Map.keys(@progress_types))
    |> Changeset.apply_action(:insert)
  end

  defp permitted_progress(attrs) do
    Enum.reduce(Map.keys(@progress_types), %{}, fn field, acc ->
      case fetch_attr(attrs, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp fetch_attr(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end

  defp fetch_catalog_item(catalog_item_id) do
    case Repo.get(CatalogItem, catalog_item_id) do
      nil -> {:error, error_changeset(:content_id, "content not found")}
      catalog_item -> {:ok, Repo.preload(catalog_item, @catalog_preloads)}
    end
  end

  defp series_id(%CatalogItem{
         content_type: "episode",
         episode: %Episode{season: %Season{} = season}
       }),
       do: season.series_id

  defp series_id(_catalog_item), do: nil

  defp decorate(%WatchProgress{} = stored, facts, catalog_item) do
    %{
      id: stored.id,
      user_id: stored.user_id,
      catalog_item_id: facts.catalog_item_id,
      catalog_item: catalog_item,
      progress_seconds: facts.progress_seconds,
      duration_seconds: facts.duration_seconds,
      completed: facts.completed,
      last_watched_at: facts.last_watched_at
    }
    |> ContentRef.decorate()
    |> Map.put(:watched_at, facts.last_watched_at)
  end

  defp error_changeset(field, message) do
    {%{}, %{content_id: :integer, content_type: :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, message)
  end

  # Opens every row of the user, newest first. Rows sealed under a key the
  # user no longer holds simply do not open and are skipped.
  defp open_all(key), do: open_where(key, dynamic(true))

  # Series are not indexed (a per-series digest would let the database group
  # a user's episodes by show), so this opens every row of the user.
  defp open_by_series(key, series_ids) do
    series_ids = MapSet.new(series_ids)
    key |> open_all() |> Enum.filter(&MapSet.member?(series_ids, &1.series_id))
  end

  defp open_where(%Key{user_id: user_id} = key, condition) do
    WatchProgress
    |> where(user_id: ^user_id)
    |> where(^condition)
    |> Repo.all()
    |> Enum.flat_map(&open_entry(key, &1))
    |> Enum.sort_by(&{&1.last_watched_at, &1.id}, &newer_or_equal?/2)
  end

  defp open_entry(key, %WatchProgress{} = row) do
    case Cipher.open_map(key, @context, row.sealed) do
      {:ok, payload} ->
        [
          %{
            id: row.id,
            user_id: row.user_id,
            item_digest: row.item_digest,
            catalog_item_id: payload["catalog_item_id"],
            content_type: payload["content_type"],
            series_id: payload["series_id"],
            progress_seconds: payload["progress_seconds"] || 0,
            duration_seconds: payload["duration_seconds"],
            completed: payload["completed"] || false,
            last_watched_at: parse_datetime(payload["last_watched_at"])
          }
        ]

      :error ->
        []
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp newer_or_equal?({left_at, left_id}, {right_at, right_id}) do
    case compare_datetimes(left_at, right_at) do
      :gt -> true
      :lt -> false
      :eq -> left_id >= right_id
    end
  end

  defp compare_datetimes(nil, nil), do: :eq
  defp compare_datetimes(nil, _right), do: :lt
  defp compare_datetimes(_left, nil), do: :gt
  defp compare_datetimes(left, right), do: DateTime.compare(left, right)

  defp latest_per_series(entries) do
    # `entries` is already newest first, so the first one per series wins.
    Enum.reduce(entries, %{}, fn entry, acc ->
      if is_integer(entry.series_id),
        do: Map.put_new(acc, entry.series_id, entry),
        else: acc
    end)
  end

  defp positive?(value), do: is_integer(value) and value > 0

  # The listing pipeline: open, filter, then resolve catalog cards in
  # newest-first chunks until the requested page is full.
  defp visible_cards(key, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)
    needed = offset + limit

    key
    |> open_all()
    |> prune_dangling(key)
    |> Enum.filter(&(is_nil(content_type) or &1.content_type == content_type))
    |> Enum.chunk_every(max(needed * 2, 50))
    |> Enum.reduce_while([], fn chunk, acc ->
      acc = acc ++ resolve_cards(key, chunk, show_adult)
      if length(acc) >= needed, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  # A provider resync can delete a catalog item a sealed row still points at.
  # The database cannot see that reference anymore, so the owner's own reads
  # move such rows to the item's successor when a sync left a redirect, and
  # drop them otherwise.
  defp prune_dangling([], _key), do: []

  defp prune_dangling(entries, %Key{user_id: user_id} = key) do
    ids = entries |> Enum.map(& &1.catalog_item_id) |> Enum.uniq()

    existing =
      from(catalog_item in CatalogItem, where: catalog_item.id in ^ids, select: catalog_item.id)
      |> Repo.all()
      |> MapSet.new()

    case Enum.split_with(entries, &MapSet.member?(existing, &1.catalog_item_id)) do
      {kept, []} ->
        kept

      {kept, dangling} ->
        successors =
          dangling
          |> Enum.map(& &1.catalog_item_id)
          |> Enum.uniq()
          |> CatalogItemRedirect.successors()

        moved = Enum.flat_map(dangling, &move_to_successor(key, &1, successors))
        dangling_ids = Enum.map(dangling, & &1.id)

        WatchProgress
        |> where([progress], progress.user_id == ^user_id and progress.id in ^dangling_ids)
        |> Repo.delete_all()

        Enum.sort_by(kept ++ moved, &{&1.last_watched_at, &1.id}, &newer_or_equal?/2)
    end
  end

  defp move_to_successor(key, entry, successors) do
    case Map.fetch(successors, entry.catalog_item_id) do
      {:ok, successor_id} -> move_entry(key, entry, successor_id)
      :error -> []
    end
  end

  # Re-seals an entry under the catalog item that replaced its own. When the
  # user already has an entry for the successor, that one wins.
  defp move_entry(key, entry, successor_id) do
    with {:ok, catalog_item} <- fetch_catalog_item(successor_id),
         facts = %{
           entry
           | catalog_item_id: successor_id,
             content_type: catalog_item.content_type,
             series_id: series_id(catalog_item)
         },
         row = sealed_row(key, facts),
         {1, [%{id: id}]} <-
           Repo.insert_all(WatchProgress, [row], on_conflict: :nothing, returning: [:id]) do
      [%{facts | id: id, item_digest: row.item_digest}]
    else
      _ -> []
    end
  end

  defp resolve_cards(_key, [], _show_adult), do: []

  defp resolve_cards(key, entries, show_adult) do
    content_by_item =
      entries
      |> Enum.map(& &1.catalog_item_id)
      |> Enum.uniq()
      |> catalog_items_query(key, show_adult)
      |> join_home_content()
      |> select_content()
      |> Repo.all()
      |> Map.new(&{&1.catalog_item_id, &1})

    entries
    |> Enum.flat_map(fn entry ->
      case Map.fetch(content_by_item, entry.catalog_item_id) do
        {:ok, content} -> [Map.merge(content, progress_fields(entry))]
        :error -> []
      end
    end)
    # Drop entries whose content row was deleted (e.g. after a provider
    # migration): the card would carry a nil content_id and crash the
    # LiveView that links to it.
    |> Enum.reject(&is_nil(content_id(&1)))
  end

  defp progress_fields(entry) do
    %{
      id: entry.id,
      user_id: entry.user_id,
      catalog_item_id: entry.catalog_item_id,
      completed: entry.completed,
      progress_seconds: entry.progress_seconds,
      duration_seconds: entry.duration_seconds,
      watched_at: entry.last_watched_at
    }
  end

  defp visible_catalog_item_ids(_key, [], _show_adult), do: MapSet.new()

  defp visible_catalog_item_ids(key, catalog_item_ids, show_adult) do
    catalog_item_ids
    |> Enum.uniq()
    |> catalog_items_query(key, show_adult)
    |> select([catalog_item: catalog_item], catalog_item.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp catalog_items_query(catalog_item_ids, %Key{user_id: user_id}, show_adult) do
    from(catalog_item in CatalogItem,
      as: :catalog_item,
      where: catalog_item.id in ^catalog_item_ids
    )
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_exclude_adult(show_adult)
  end

  defp episode_ids_by_catalog_item([]), do: %{}

  defp episode_ids_by_catalog_item(catalog_item_ids) do
    from(episode in Episode,
      where: episode.catalog_item_id in ^catalog_item_ids,
      select: {episode.catalog_item_id, episode.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp item_digest(key, catalog_item_id),
    do: Cipher.digest(key, @digest_namespace, catalog_item_id)

  defp maybe_exclude_adult(query, true), do: query
  defp maybe_exclude_adult(query, false), do: ContentPolicy.exclude_adult(query)

  defp join_home_content(query) do
    query
    |> join(:left, [catalog_item: catalog_item], movie in assoc(catalog_item, :movie), as: :movie)
    |> join(:left, [catalog_item: catalog_item], series in assoc(catalog_item, :series),
      as: :series
    )
    |> join(:left, [catalog_item: catalog_item], episode in assoc(catalog_item, :episode),
      as: :episode
    )
    |> join(:left, [catalog_item: catalog_item], channel in assoc(catalog_item, :live_channel),
      as: :channel
    )
    |> join(:left, [episode: episode], season in assoc(episode, :season), as: :episode_season)
    |> join(:left, [episode_season: season], series in assoc(season, :series),
      as: :episode_series
    )
  end

  defp select_content(query) do
    select(
      query,
      [
        catalog_item: catalog_item,
        movie: movie,
        series: series,
        episode: episode,
        episode_season: episode_season,
        episode_series: episode_series,
        channel: channel
      ],
      %{
        catalog_item_id: catalog_item.id,
        content_type: catalog_item.content_type,
        movie_id: movie.id,
        movie_name: movie.name,
        movie_icon: movie.stream_icon,
        movie_tmdb_id: movie.tmdb_id,
        series_id: series.id,
        series_name: series.name,
        series_icon: series.cover,
        episode_id: episode.id,
        episode_name: episode.title,
        episode_raw_name: episode.name,
        episode_icon: episode.still_path,
        episode_cover: episode.cover,
        episode_num: episode.episode_num,
        episode_season_number: episode_season.season_number,
        episode_series_id: episode_season.series_id,
        episode_series_name: episode_series.name,
        episode_series_title: episode_series.title,
        episode_series_cover: episode_series.cover,
        episode_series_tmdb_id: episode_series.tmdb_id,
        live_channel_id: channel.id,
        live_channel_name: channel.name,
        live_channel_icon: channel.stream_icon
      }
    )
  end

  defp content_id(%{content_type: "movie"} = row), do: row.movie_id
  defp content_id(%{content_type: "series"} = row), do: row.series_id
  defp content_id(%{content_type: "episode"} = row), do: row.episode_id
  defp content_id(%{content_type: "live_channel"} = row), do: row.live_channel_id
  defp content_id(_row), do: nil

  defp build_history_entry(row) do
    row
    |> build_home_card()
    |> Map.merge(%{
      user_id: row.user_id,
      catalog_item_id: row.catalog_item_id,
      completed: row.completed,
      last_watched_at: row.watched_at
    })
  end

  defp build_home_card(%{content_type: "movie"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.movie_id,
      content_name: row.movie_name,
      content_icon: row.movie_icon,
      tmdb_id: row.movie_tmdb_id
    }
  end

  defp build_home_card(%{content_type: "series"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.series_id,
      content_name: row.series_name,
      content_icon: row.series_icon
    }
  end

  # An episode title alone ("Piloto") does not say what to resume, so the
  # card also carries its series and position.
  defp build_home_card(%{content_type: "episode"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.episode_id,
      content_name: row.episode_name || row.episode_raw_name,
      content_icon: row.episode_icon || row.episode_cover || row.episode_series_cover,
      series_name: row.episode_series_name || row.episode_series_title,
      series_tmdb_id: row.episode_series_tmdb_id,
      season_number: row.episode_season_number,
      episode_number: row.episode_num
    }
  end

  defp build_home_card(%{content_type: "live_channel"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.live_channel_id,
      content_name: row.live_channel_name,
      content_icon: row.live_channel_icon
    }
  end

  defp content_schema("live_channel"), do: Streamix.Iptv.LiveChannel
  defp content_schema("movie"), do: Streamix.Iptv.Movie
  defp content_schema("episode"), do: Streamix.Iptv.Episode
  defp content_schema("series"), do: Streamix.Iptv.Series
  defp content_schema(_), do: nil
end
