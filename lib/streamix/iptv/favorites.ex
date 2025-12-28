defmodule Streamix.Iptv.Favorites do
  @moduledoc """
  Polymorphic favorites management.

  Handles favorites for any content type (live_channel, movie, series, episode).
  Provides listing, checking, adding, removing, and toggling operations.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Favorite
  alias Streamix.Repo

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

    query = if content_type, do: where(query, content_type: ^content_type), else: query

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Checks if content is favorited by a user.
  """
  @spec exists?(integer(), String.t(), integer()) :: boolean()
  def exists?(user_id, content_type, content_id) do
    Favorite
    |> where(user_id: ^user_id, content_type: ^content_type, content_id: ^content_id)
    |> Repo.exists?()
  end

  @doc """
  Alias for `exists?/3` for LiveView naming conventions.
  """
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  @spec is_favorite?(integer(), String.t(), integer()) :: boolean()
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
    |> group_by([f], f.content_type)
    |> select([f], {f.content_type, count(f.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Lists only the content_ids of favorites for a user, filtered by content_type.
  Returns a MapSet for O(1) lookup in list views.
  """
  @spec list_ids(integer(), String.t()) :: MapSet.t()
  def list_ids(user_id, content_type) do
    Favorite
    |> where(user_id: ^user_id, content_type: ^content_type)
    |> select([f], f.content_id)
    |> Repo.all()
    |> MapSet.new()
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
    %Favorite{}
    |> Favorite.changeset(Map.merge(attrs, %{user_id: user_id}))
    |> Repo.insert()
  end

  @doc """
  Adds a favorite with explicit content type and id.
  """
  @spec add(integer(), String.t(), integer(), map()) ::
          {:ok, Favorite.t()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, attrs \\ %{}) do
    %Favorite{}
    |> Favorite.changeset(
      Map.merge(attrs, %{
        user_id: user_id,
        content_type: content_type,
        content_id: content_id
      })
    )
    |> Repo.insert()
  end

  @doc """
  Removes a favorite. Returns {:ok, count} where count is 0 or 1.
  """
  @spec remove(integer(), String.t(), integer()) :: {:ok, integer()}
  def remove(user_id, content_type, content_id) do
    {count, _} =
      Favorite
      |> where(user_id: ^user_id, content_type: ^content_type, content_id: ^content_id)
      |> Repo.delete_all()

    {:ok, count}
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
end
