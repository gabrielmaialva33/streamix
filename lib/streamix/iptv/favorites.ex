defmodule Streamix.Iptv.Favorites do
  @moduledoc """
  Favorites management backed by concrete content foreign keys.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.Favorite
  alias Streamix.Library.ContentRef
  alias Streamix.Repo

  @content_types ContentRef.favorite_types()
  @preloads [:live_channel, :movie, :series, :episode]

  @doc """
  Lists favorites for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "series", "live_channel", "episode")
  """
  @spec list(integer(), keyword()) :: [Favorite.t()]
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)

    query =
      Favorite
      |> where(user_id: ^user_id)
      |> order_by(desc: :inserted_at)
      |> preload(^@preloads)

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
    case normalized_content_field_and_id(content_type, content_id) do
      {:ok, field, normalized_id} ->
        Favorite
        |> where(user_id: ^user_id)
        |> where([f], field(f, ^field) == ^normalized_id)
        |> Repo.exists?()

      {:error, _reason} ->
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
    @content_types
    |> Enum.reduce(%{}, fn type, acc ->
      count =
        Favorite
        |> where(user_id: ^user_id)
        |> maybe_filter_by_type(type)
        |> Repo.aggregate(:count)

      if count > 0, do: Map.put(acc, type, count), else: acc
    end)
  end

  @doc """
  Lists only the content_ids of favorites for a user, filtered by content_type.
  Returns a MapSet for O(1) lookup in list views.
  """
  @spec list_ids(integer(), String.t()) :: MapSet.t()
  def list_ids(user_id, content_type) do
    case content_field(content_type) do
      {:ok, field} ->
        Favorite
        |> where(user_id: ^user_id)
        |> where([f], not is_nil(field(f, ^field)))
        |> select([f], field(f, ^field))
        |> Repo.all()
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
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
  @spec add(integer(), map()) :: {:ok, Favorite.t()} | {:error, Ecto.Changeset.t()}
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
  @spec add(integer(), String.t(), integer(), map()) ::
          {:ok, Favorite.t()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, attrs \\ %{}) do
    case ContentRef.resolve_target_attrs(content_type, content_id, @content_types) do
      {:ok, target_attrs} ->
        %Favorite{}
        |> Favorite.changeset(Map.merge(attrs, Map.put(target_attrs, :user_id, user_id)))
        |> Repo.insert()
        |> maybe_decorate()

      {:error, :invalid_content_type} ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_type, "is invalid")}

      {:error, :invalid_content_id} ->
        {:error,
         Changeset.change(%Favorite{})
         |> Changeset.add_error(:content_id, "is invalid")}
    end
  end

  @doc """
  Removes a favorite. Returns {:ok, count} where count is 0 or 1.
  """
  @spec remove(integer(), String.t(), integer()) :: {:ok, integer()}
  def remove(user_id, content_type, content_id) do
    case normalized_content_field_and_id(content_type, content_id) do
      {:ok, field, normalized_id} ->
        {count, _} =
          Favorite
          |> where(user_id: ^user_id)
          |> where([f], field(f, ^field) == ^normalized_id)
          |> Repo.delete_all()

        {:ok, count}

      {:error, _reason} ->
        {:ok, 0}
    end
  end

  @doc """
  Toggles a favorite. Returns {:ok, :added} or {:ok, :removed}.
  """
  @spec toggle(integer(), String.t(), integer(), map()) ::
          {:ok, :added | :removed} | {:error, Ecto.Changeset.t()}
  def toggle(user_id, content_type, content_id, attrs \\ %{}) do
    if exists?(user_id, content_type, content_id) do
      remove(user_id, content_type, content_id)
      {:ok, :removed}
    else
      case add(user_id, content_type, content_id, attrs) do
        {:ok, _} -> {:ok, :added}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, content_type) do
    case content_field(content_type) do
      {:ok, field} ->
        where(query, [f], not is_nil(field(f, ^field)))

      {:error, _reason} ->
        where(query, [f], false)
    end
  end

  defp normalized_content_field_and_id(content_type, content_id) do
    with {:ok, field} <- content_field(content_type),
         {:ok, normalized_id} <- normalize_id(content_id) do
      {:ok, field, normalized_id}
    end
  end

  defp content_field(content_type) do
    case ContentRef.target_field(content_type) do
      nil -> {:error, :invalid_content_type}
      field -> {:ok, field}
    end
  end

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {normalized_id, ""} when normalized_id > 0 -> {:ok, normalized_id}
      _ -> {:error, :invalid_content_id}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_content_id}

  defp maybe_decorate({:ok, favorite}) do
    favorite
    |> Repo.preload(@preloads)
    |> ContentRef.decorate()
    |> then(&{:ok, &1})
  end

  defp maybe_decorate({:error, changeset}), do: {:error, changeset}
end
