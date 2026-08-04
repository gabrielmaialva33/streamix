defmodule Streamix.Iptv.Favorites do
  @moduledoc """
  Favorites management backed by catalog_item_id references.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.{CatalogItem, Favorite}
  alias Streamix.Iptv.ContentRef
  alias Streamix.Iptv.Engagement.ContentPolicy
  alias Streamix.Repo

  @content_types ContentRef.favorite_types()
  @catalog_preloads [catalog_item: [:movie, :series, :episode, :live_channel]]

  @doc """
  Lists favorites for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "series", "live_channel", "episode")
  """
  @spec list(integer(), keyword()) :: [map()]
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)

    user_favorites_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_filter_by_type(content_type)
    |> maybe_exclude_adult(show_adult)
    |> order_by([favorite: favorite], desc: favorite.inserted_at)
    |> preload(^@catalog_preloads)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Enum.map(&ContentRef.decorate/1)
  end

  @doc """
  Lists lightweight favorite cards for home surfaces without generic content preloads.
  """
  @spec list_home(integer(), keyword()) :: [map()]
  def list_home(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)

    user_favorites_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_filter_by_type(content_type)
    |> maybe_exclude_adult(show_adult)
    |> join_home_content()
    |> order_by([favorite: favorite], desc: favorite.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> select_home_card()
    |> Repo.all()
    |> Enum.map(&build_home_card/1)
  end

  @doc """
  Checks if content is favorited by a user.
  """
  @spec exists?(integer(), String.t(), integer()) :: boolean()
  def exists?(user_id, content_type, content_id) do
    case ContentRef.resolve_catalog_item_id(content_type, content_id) do
      {:ok, catalog_item_id} ->
        Favorite
        |> where(user_id: ^user_id, catalog_item_id: ^catalog_item_id)
        |> Repo.exists?()

      {:error, _} ->
        false
    end
  end

  @doc """
  Alias for `exists?/3` for LiveView naming conventions.
  """
  @spec favorite?(integer(), String.t(), integer()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def favorite?(user_id, content_type, content_id) do
    exists?(user_id, content_type, content_id)
  end

  @doc """
  Counts favorites grouped by content type for a user.
  Returns a map like %{"movie" => 10, "series" => 5, "live_channel" => 3}
  """
  @spec count_by_type(integer(), keyword()) :: %{String.t() => integer()}
  def count_by_type(user_id, opts \\ []) do
    Favorite
    |> user_favorites_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false))
    |> group_by([catalog_item: catalog_item], catalog_item.content_type)
    |> select([catalog_item: catalog_item], {catalog_item.content_type, count()})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Lists only the content_ids of favorites for a user, filtered by content_type.
  Returns a MapSet for O(1) lookup in list views.
  """
  @spec list_ids(integer(), String.t(), [integer()] | nil) :: MapSet.t(integer())
  def list_ids(user_id, content_type, content_ids \\ nil) do
    case content_schema(content_type) do
      nil ->
        MapSet.new()

      schema ->
        schema
        |> favorite_content_ids_query(user_id, content_type)
        |> maybe_filter_content_ids(content_ids)
        |> Repo.all()
        |> MapSet.new()
    end
  end

  @doc """
  Counts total favorites for a user.
  """
  @spec count(integer(), keyword()) :: integer()
  def count(user_id, opts \\ []) do
    Favorite
    |> user_favorites_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false))
    |> Repo.aggregate(:count)
  end

  @doc """
  Adds a favorite from a map of attributes.
  """
  @spec add(integer(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(user_id, attrs) when is_map(attrs) do
    with type when is_binary(type) <- attrs[:content_type] || attrs["content_type"],
         id when not is_nil(id) <- attrs[:content_id] || attrs["content_id"] do
      add(user_id, type, id)
    else
      _ ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_type, "is invalid")}
    end
  end

  @doc """
  Adds a favorite with explicit content type and id.
  """
  @spec add(integer(), String.t(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, _attrs \\ %{}) do
    with :ok <- validate_content_type(content_type),
         {:ok, normalized_id} <- ContentRef.normalize_id(content_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(content_type, normalized_id),
         true <- ContentPolicy.visible_catalog_item?(user_id, catalog_item_id) do
      %Favorite{}
      |> Favorite.changeset(%{user_id: user_id, catalog_item_id: catalog_item_id})
      |> Repo.insert()
      |> maybe_decorate()
    else
      {:error, :invalid_content_id} ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_id, "is invalid")}

      {:error, :not_found} ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_id, "content not found")}

      {:error, :invalid_content_type} ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_type, "is invalid")}

      false ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_id, "content not found")}
    end
  end

  @doc """
  Removes a favorite. Returns {:ok, count} where count is 0 or 1.
  """
  @spec remove(integer(), String.t(), integer()) :: {:ok, integer()}
  def remove(user_id, content_type, content_id) do
    case ContentRef.resolve_catalog_item_id(content_type, content_id) do
      {:ok, catalog_item_id} ->
        {count, _} =
          Favorite
          |> where(user_id: ^user_id, catalog_item_id: ^catalog_item_id)
          |> Repo.delete_all()

        {:ok, count}

      {:error, _} ->
        {:ok, 0}
    end
  end

  @doc """
  Toggles a favorite. Returns {:ok, :added} or {:ok, :removed}.
  """
  @spec toggle(integer(), String.t(), integer(), map()) ::
          {:ok, :added | :removed} | {:error, Ecto.Changeset.t()}
  def toggle(user_id, content_type, content_id, _attrs \\ %{}) do
    if exists?(user_id, content_type, content_id) do
      remove(user_id, content_type, content_id)
      {:ok, :removed}
    else
      case add(user_id, content_type, content_id) do
        {:ok, _} -> {:ok, :added}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp user_favorites_query(user_id), do: user_favorites_query(Favorite, user_id)

  defp user_favorites_query(queryable, user_id) do
    from(favorite in queryable,
      as: :favorite,
      where: favorite.user_id == ^user_id,
      join: catalog_item in CatalogItem,
      as: :catalog_item,
      on: favorite.catalog_item_id == catalog_item.id
    )
  end

  defp validate_content_type(content_type) when content_type in @content_types, do: :ok
  defp validate_content_type(_content_type), do: {:error, :invalid_content_type}

  defp favorite_content_ids_query(schema, user_id, content_type) do
    from(content in schema,
      as: :content,
      join: favorite in Favorite,
      as: :favorite,
      on: favorite.catalog_item_id == content.catalog_item_id,
      join: catalog_item in CatalogItem,
      as: :catalog_item,
      on: catalog_item.id == favorite.catalog_item_id,
      where: favorite.user_id == ^user_id,
      where: catalog_item.content_type == ^content_type,
      select: content.id
    )
  end

  defp maybe_filter_content_ids(query, nil), do: query
  defp maybe_filter_content_ids(query, []), do: where(query, false)

  defp maybe_filter_content_ids(query, content_ids) when is_list(content_ids) do
    where(query, [content: content], content.id in ^content_ids)
  end

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, content_type) do
    where(query, [catalog_item: catalog_item], catalog_item.content_type == ^content_type)
  end

  defp maybe_exclude_adult(query, true), do: query

  defp maybe_exclude_adult(query, _show_adult),
    do: ContentPolicy.exclude_adult(query)

  defp maybe_decorate({:ok, favorite}) do
    favorite
    |> Repo.preload(@catalog_preloads)
    |> ContentRef.decorate()
    |> then(&{:ok, &1})
  end

  defp maybe_decorate({:error, changeset}), do: {:error, changeset}

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

  defp select_home_card(query) do
    select(
      query,
      [
        favorite: favorite,
        catalog_item: catalog_item,
        movie: movie,
        series: series,
        episode: episode,
        channel: channel
      ],
      %{
        inserted_at: favorite.inserted_at,
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
