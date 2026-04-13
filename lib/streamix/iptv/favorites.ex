defmodule Streamix.Iptv.Favorites do
  @moduledoc """
  Favorites management backed by catalog_item_id references.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.{CatalogItem, Favorite}
  alias Streamix.Library.ContentRef
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

    query =
      Favorite
      |> where(user_id: ^user_id)
      |> join(:inner, [f], ci in CatalogItem, on: f.catalog_item_id == ci.id)
      |> order_by([f], desc: f.inserted_at)
      |> preload(^@catalog_preloads)

    query = maybe_filter_by_type(query, content_type)

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Enum.map(&ContentRef.decorate/1)
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
  @spec is_favorite?(integer(), String.t(), integer()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_favorite?(user_id, content_type, content_id) do
    exists?(user_id, content_type, content_id)
  end

  @doc """
  Counts favorites grouped by content type for a user.
  Returns a map like %{"movie" => 10, "series" => 5, "live_channel" => 3}
  """
  @spec count_by_type(integer()) :: %{String.t() => integer()}
  def count_by_type(user_id) do
    Favorite
    |> where(user_id: ^user_id)
    |> join(:inner, [f], ci in CatalogItem, on: f.catalog_item_id == ci.id)
    |> group_by([_f, ci], ci.content_type)
    |> select([_f, ci], {ci.content_type, count()})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Lists only the content_ids of favorites for a user, filtered by content_type.
  Returns a MapSet for O(1) lookup in list views.
  """
  @spec list_ids(integer(), String.t()) :: MapSet.t(integer())
  def list_ids(user_id, content_type) do
    # Get catalog_item_ids for this user's favorites of the given type
    catalog_item_ids =
      Favorite
      |> where(user_id: ^user_id)
      |> join(:inner, [f], ci in CatalogItem, on: f.catalog_item_id == ci.id)
      |> where([_f, ci], ci.content_type == ^content_type)
      |> select([f, _ci], f.catalog_item_id)
      |> Repo.all()

    # Resolve those to actual content ids
    if catalog_item_ids == [] do
      MapSet.new()
    else
      schema = content_schema(content_type)

      if schema do
        schema
        |> where([c], c.catalog_item_id in ^catalog_item_ids)
        |> select([c], c.id)
        |> Repo.all()
        |> MapSet.new()
      else
        MapSet.new()
      end
    end
  end

  @doc """
  Counts total favorites for a user.
  """
  @spec count(integer()) :: integer()
  def count(user_id) do
    Favorite
    |> where(user_id: ^user_id)
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
    with true <- content_type in @content_types,
         {:ok, normalized_id} <- ContentRef.normalize_id(content_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(content_type, normalized_id) do
      %Favorite{}
      |> Favorite.changeset(%{user_id: user_id, catalog_item_id: catalog_item_id})
      |> Repo.insert()
      |> maybe_decorate()
    else
      false ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_type, "is invalid")}

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

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, content_type) do
    where(query, [_f, ci], ci.content_type == ^content_type)
  end

  defp maybe_decorate({:ok, favorite}) do
    favorite
    |> Repo.preload(@catalog_preloads)
    |> ContentRef.decorate()
    |> then(&{:ok, &1})
  end

  defp maybe_decorate({:error, changeset}), do: {:error, changeset}

  defp content_schema("live_channel"), do: Streamix.Iptv.LiveChannel
  defp content_schema("movie"), do: Streamix.Iptv.Movie
  defp content_schema("series"), do: Streamix.Iptv.Series
  defp content_schema("episode"), do: Streamix.Iptv.Episode
  defp content_schema(_), do: nil
end
