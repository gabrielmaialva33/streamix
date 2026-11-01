defmodule Streamix.Iptv.Favorites do
  @moduledoc """
  Favorites, sealed with the user's library key.

  Like `Streamix.Iptv.History`, rows only hold an HMAC of the content and its
  ciphertext (see `Streamix.Iptv.Favorite`). Membership checks go through the
  blind index; listings open the user's rows and resolve the catalog after.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.{CatalogItem, CatalogItemRedirect, Favorite}
  alias Streamix.Iptv.ContentRef
  alias Streamix.Iptv.Engagement.ContentPolicy
  alias Streamix.Library.{Cipher, Key}
  alias Streamix.Repo

  @context "favorite"
  @digest_namespace "favorite:catalog_item"
  @content_types ContentRef.favorite_types()
  @catalog_preloads [:movie, :series, :episode, :live_channel]

  @doc """
  Lists favorites for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "series", "live_channel", "episode")
  """
  @spec list(Key.t(), keyword()) :: [map()]
  def list(%Key{} = key, opts \\ []) do
    paginate(key, opts, 100, fn entries, show_adult ->
      catalog_items =
        entries
        |> catalog_item_ids()
        |> catalog_items_query(key, show_adult)
        |> preload(^@catalog_preloads)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})

      Enum.flat_map(entries, &decorate_entry(&1, catalog_items))
    end)
  end

  @doc """
  Lists lightweight favorite cards for home surfaces without generic content preloads.
  """
  @spec list_home(Key.t(), keyword()) :: [map()]
  def list_home(%Key{} = key, opts \\ []) do
    paginate(key, opts, 100, fn entries, show_adult ->
      content_by_item =
        entries
        |> catalog_item_ids()
        |> catalog_items_query(key, show_adult)
        |> join_home_content()
        |> select_content()
        |> Repo.all()
        |> Map.new(&{&1.catalog_item_id, &1})

      Enum.flat_map(entries, &home_card(&1, content_by_item))
    end)
  end

  @doc """
  Checks if content is favorited by a user.
  """
  @spec exists?(Key.t(), String.t(), integer()) :: boolean()
  def exists?(%Key{user_id: user_id} = key, content_type, content_id) do
    case ContentRef.resolve_catalog_item_id(content_type, content_id) do
      {:ok, catalog_item_id} ->
        Favorite
        |> where(user_id: ^user_id, item_digest: ^item_digest(key, catalog_item_id))
        |> Repo.exists?()

      {:error, _} ->
        false
    end
  end

  @doc """
  Alias for `exists?/3` for LiveView naming conventions.
  """
  @spec favorite?(Key.t(), String.t(), integer()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def favorite?(%Key{} = key, content_type, content_id) do
    exists?(key, content_type, content_id)
  end

  @doc """
  Counts favorites grouped by content type for a user.
  Returns a map like %{"movie" => 10, "series" => 5, "live_channel" => 3}
  """
  @spec count_by_type(Key.t(), keyword()) :: %{String.t() => integer()}
  def count_by_type(%Key{} = key, opts \\ []) do
    key
    |> visible_entries(Keyword.get(opts, :show_adult, false))
    |> Enum.frequencies_by(& &1.content_type)
  end

  @doc """
  Lists only the content_ids of favorites for a user, filtered by content_type.
  Returns a MapSet for O(1) lookup in list views.
  """
  @spec list_ids(Key.t(), String.t(), [integer()] | nil) :: MapSet.t(integer())
  def list_ids(key, content_type, content_ids \\ nil)

  def list_ids(_key, _content_type, []), do: MapSet.new()

  def list_ids(%Key{} = key, content_type, nil) do
    case content_schema(content_type) do
      nil ->
        MapSet.new()

      schema ->
        catalog_item_ids =
          key
          |> open_all()
          |> Enum.filter(&(&1.content_type == content_type))
          |> catalog_item_ids()

        from(content in schema,
          where: content.catalog_item_id in ^catalog_item_ids,
          select: content.id
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end

  def list_ids(%Key{user_id: user_id} = key, content_type, content_ids)
      when is_list(content_ids) do
    case content_schema(content_type) do
      nil ->
        MapSet.new()

      schema ->
        content_by_digest =
          from(content in schema,
            where: content.id in ^content_ids,
            select: {content.id, content.catalog_item_id}
          )
          |> Repo.all()
          |> Map.new(fn {id, catalog_item_id} -> {item_digest(key, catalog_item_id), id} end)

        from(favorite in Favorite,
          where: favorite.user_id == ^user_id,
          where: favorite.item_digest in ^Map.keys(content_by_digest),
          select: favorite.item_digest
        )
        |> Repo.all()
        |> MapSet.new(&Map.fetch!(content_by_digest, &1))
    end
  end

  @doc """
  Counts total favorites for a user.
  """
  @spec count(Key.t(), keyword()) :: integer()
  def count(%Key{} = key, opts \\ []) do
    key
    |> visible_entries(Keyword.get(opts, :show_adult, false))
    |> length()
  end

  @doc """
  Adds a favorite from a map of attributes.
  """
  @spec add(Key.t(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(%Key{} = key, attrs) when is_map(attrs) do
    with type when is_binary(type) <- attrs[:content_type] || attrs["content_type"],
         id when not is_nil(id) <- attrs[:content_id] || attrs["content_id"] do
      add(key, type, id)
    else
      _ -> {:error, error_changeset(:content_type, "is invalid")}
    end
  end

  @doc """
  Adds a favorite with explicit content type and id.
  """
  @spec add(Key.t(), String.t(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(%Key{} = key, content_type, content_id, _attrs \\ %{}) do
    with :ok <- validate_content_type(content_type),
         {:ok, normalized_id} <- ContentRef.normalize_id(content_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(content_type, normalized_id),
         true <- ContentPolicy.visible_catalog_item?(key.user_id, catalog_item_id) do
      facts = %{
        catalog_item_id: catalog_item_id,
        content_type: content_type,
        inserted_at: DateTime.utc_now(:second)
      }

      %Favorite{}
      |> Favorite.changeset(sealed_row(key, facts))
      |> Repo.insert()
      |> case do
        {:ok, favorite} -> {:ok, decorate(favorite, facts)}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :invalid_content_id} -> {:error, error_changeset(:content_id, "is invalid")}
      {:error, :not_found} -> {:error, error_changeset(:content_id, "content not found")}
      {:error, :invalid_content_type} -> {:error, error_changeset(:content_type, "is invalid")}
      false -> {:error, error_changeset(:content_id, "content not found")}
    end
  end

  @doc """
  Removes a favorite. Returns {:ok, count} where count is 0 or 1.
  """
  @spec remove(Key.t(), String.t(), integer()) :: {:ok, integer()}
  def remove(%Key{user_id: user_id} = key, content_type, content_id) do
    case ContentRef.resolve_catalog_item_id(content_type, content_id) do
      {:ok, catalog_item_id} ->
        {count, _} =
          Favorite
          |> where(user_id: ^user_id, item_digest: ^item_digest(key, catalog_item_id))
          |> Repo.delete_all()

        {:ok, count}

      {:error, _} ->
        {:ok, 0}
    end
  end

  @doc """
  Toggles a favorite. Returns {:ok, :added} or {:ok, :removed}.
  """
  @spec toggle(Key.t(), String.t(), integer(), map()) ::
          {:ok, :added | :removed} | {:error, Ecto.Changeset.t()}
  def toggle(%Key{} = key, content_type, content_id, _attrs \\ %{}) do
    if exists?(key, content_type, content_id) do
      remove(key, content_type, content_id)
      {:ok, :removed}
    else
      case add(key, content_type, content_id) do
        {:ok, _} -> {:ok, :added}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "Deletes every favorite of a user."
  @spec clear(integer()) :: {:ok, integer()}
  def clear(user_id) when is_integer(user_id) do
    {count, _} = Favorite |> where(user_id: ^user_id) |> Repo.delete_all()
    {:ok, count}
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
          "inserted_at" => DateTime.to_iso8601(facts.inserted_at)
        })
    }
  end

  # --- Private ---

  defp paginate(key, opts, default_limit, resolve) do
    limit = Keyword.get(opts, :limit, default_limit)
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
      acc = acc ++ resolve.(chunk, show_adult)
      if length(acc) >= needed, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  defp visible_entries(key, show_adult) do
    entries = open_all(key)

    visible =
      case catalog_item_ids(entries) do
        [] ->
          MapSet.new()

        ids ->
          ids
          |> catalog_items_query(key, show_adult)
          |> select([catalog_item: catalog_item], catalog_item.id)
          |> Repo.all()
          |> MapSet.new()
      end

    Enum.filter(entries, &MapSet.member?(visible, &1.catalog_item_id))
  end

  # Newest first; rows sealed under a key the user no longer holds are skipped.
  # When a favorite was added lives inside the sealed payload, so the sorting
  # happens here rather than in SQL.
  defp open_all(%Key{user_id: user_id} = key) do
    Favorite
    |> where(user_id: ^user_id)
    |> Repo.all()
    |> Enum.flat_map(&open_entry(key, &1))
    |> Enum.sort_by(&{&1.inserted_at, &1.id}, &newer_or_equal?/2)
  end

  defp open_entry(key, %Favorite{} = favorite) do
    with {:ok, payload} <- Cipher.open_map(key, @context, favorite.sealed),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(payload["inserted_at"] || "") do
      [
        %{
          id: favorite.id,
          user_id: favorite.user_id,
          inserted_at: DateTime.truncate(inserted_at, :second),
          catalog_item_id: payload["catalog_item_id"],
          content_type: payload["content_type"]
        }
      ]
    else
      _ -> []
    end
  end

  # A provider resync can delete a catalog item a sealed favorite still
  # points at; only the owner's reads can notice. They move the favorite to
  # the item's successor when a sync left a redirect, and drop it otherwise.
  defp prune_dangling([], _key), do: []

  defp prune_dangling(entries, %Key{user_id: user_id} = key) do
    ids = catalog_item_ids(entries)

    existing =
      from(catalog_item in CatalogItem, where: catalog_item.id in ^ids, select: catalog_item.id)
      |> Repo.all()
      |> MapSet.new()

    case Enum.split_with(entries, &MapSet.member?(existing, &1.catalog_item_id)) do
      {kept, []} ->
        kept

      {kept, dangling} ->
        successors = dangling |> catalog_item_ids() |> CatalogItemRedirect.successors()

        moved = Enum.flat_map(dangling, &move_to_successor(key, &1, successors))
        dangling_ids = Enum.map(dangling, & &1.id)

        Favorite
        |> where([favorite], favorite.user_id == ^user_id and favorite.id in ^dangling_ids)
        |> Repo.delete_all()

        Enum.sort_by(kept ++ moved, &{&1.inserted_at, &1.id}, &newer_or_equal?/2)
    end
  end

  defp move_to_successor(key, entry, successors) do
    case Map.fetch(successors, entry.catalog_item_id) do
      {:ok, successor_id} -> move_entry(key, entry, successor_id)
      :error -> []
    end
  end

  # Re-seals a favorite under the catalog item that replaced its own. When the
  # user already favorited the successor, that favorite wins.
  defp move_entry(key, entry, successor_id) do
    with %CatalogItem{} = catalog_item <- Repo.get(CatalogItem, successor_id),
         facts = %{
           catalog_item_id: successor_id,
           content_type: catalog_item.content_type,
           inserted_at: entry.inserted_at
         },
         row = sealed_row(key, facts),
         {1, [%{id: id}]} <-
           Repo.insert_all(Favorite, [row], on_conflict: :nothing, returning: [:id]) do
      [Map.merge(entry, Map.put(facts, :id, id))]
    else
      _ -> []
    end
  end

  defp newer_or_equal?({left_at, left_id}, {right_at, right_id}) do
    case DateTime.compare(left_at, right_at) do
      :gt -> true
      :lt -> false
      :eq -> left_id >= right_id
    end
  end

  # Entries whose catalog item is not visible to the user (or not shown with
  # the adult filter on) have no match and are left out.
  defp decorate_entry(entry, catalog_items) do
    case Map.fetch(catalog_items, entry.catalog_item_id) do
      {:ok, catalog_item} ->
        [entry |> Map.put(:catalog_item, catalog_item) |> ContentRef.decorate()]

      :error ->
        []
    end
  end

  defp home_card(entry, content_by_item) do
    case Map.fetch(content_by_item, entry.catalog_item_id) do
      {:ok, content} -> [build_home_card(Map.put(content, :inserted_at, entry.inserted_at))]
      :error -> []
    end
  end

  defp catalog_item_ids(entries), do: entries |> Enum.map(& &1.catalog_item_id) |> Enum.uniq()

  defp catalog_items_query(catalog_item_ids, %Key{user_id: user_id}, show_adult) do
    from(catalog_item in CatalogItem,
      as: :catalog_item,
      where: catalog_item.id in ^catalog_item_ids
    )
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_exclude_adult(show_adult)
  end

  defp item_digest(key, catalog_item_id),
    do: Cipher.digest(key, @digest_namespace, catalog_item_id)

  defp decorate(%Favorite{} = favorite, facts) do
    catalog_item =
      CatalogItem |> Repo.get!(facts.catalog_item_id) |> Repo.preload(@catalog_preloads)

    ContentRef.decorate(%{
      id: favorite.id,
      user_id: favorite.user_id,
      inserted_at: facts.inserted_at,
      catalog_item_id: facts.catalog_item_id,
      catalog_item: catalog_item
    })
  end

  defp error_changeset(field, message) do
    {%{}, %{content_id: :integer, content_type: :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, message)
  end

  defp validate_content_type(content_type) when content_type in @content_types, do: :ok
  defp validate_content_type(_content_type), do: {:error, :invalid_content_type}

  defp maybe_exclude_adult(query, true), do: query

  defp maybe_exclude_adult(query, _show_adult),
    do: ContentPolicy.exclude_adult(query)

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
  end

  defp select_content(query) do
    select(
      query,
      [
        catalog_item: catalog_item,
        movie: movie,
        series: series,
        episode: episode,
        channel: channel
      ],
      %{
        catalog_item_id: catalog_item.id,
        content_type: catalog_item.content_type,
        movie_id: movie.id,
        movie_name: movie.name,
        movie_icon: movie.stream_icon,
        series_id: series.id,
        series_name: series.name,
        series_icon: series.cover,
        episode_id: episode.id,
        episode_name: episode.title,
        episode_icon: episode.still_path,
        live_channel_id: channel.id,
        live_channel_name: channel.name,
        live_channel_icon: channel.stream_icon
      }
    )
  end

  defp build_home_card(%{content_type: "movie"} = row) do
    %{
      inserted_at: row.inserted_at,
      content_type: row.content_type,
      content_id: row.movie_id,
      content_name: row.movie_name,
      content_icon: row.movie_icon
    }
  end

  defp build_home_card(%{content_type: "series"} = row) do
    %{
      inserted_at: row.inserted_at,
      content_type: row.content_type,
      content_id: row.series_id,
      content_name: row.series_name,
      content_icon: row.series_icon
    }
  end

  defp build_home_card(%{content_type: "episode"} = row) do
    %{
      inserted_at: row.inserted_at,
      content_type: row.content_type,
      content_id: row.episode_id,
      content_name: row.episode_name,
      content_icon: row.episode_icon
    }
  end

  defp build_home_card(%{content_type: "live_channel"} = row) do
    %{
      inserted_at: row.inserted_at,
      content_type: row.content_type,
      content_id: row.live_channel_id,
      content_name: row.live_channel_name,
      content_icon: row.live_channel_icon
    }
  end

  defp content_schema("live_channel"), do: Streamix.Iptv.LiveChannel
  defp content_schema("movie"), do: Streamix.Iptv.Movie
  defp content_schema("series"), do: Streamix.Iptv.Series
  defp content_schema("episode"), do: Streamix.Iptv.Episode
  defp content_schema(_), do: nil
end
