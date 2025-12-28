defmodule Streamix.Iptv.History do
  @moduledoc """
  Polymorphic watch history management.

  Tracks viewing progress for any content type (live_channel, movie, episode).
  Provides listing, adding, updating progress, and clearing operations.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.WatchHistory
  alias Streamix.Repo

  @doc """
  Lists watch history for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 50)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "episode", "live_channel")
  """
  @spec list(integer(), keyword()) :: [WatchHistory.t()]
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)

    query =
      WatchHistory
      |> where(user_id: ^user_id)
      |> order_by(desc: :watched_at)

    query = if content_type, do: where(query, content_type: ^content_type), else: query

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts watch history grouped by content type for a user.
  Returns a map like %{"movie" => 10, "episode" => 15, "live_channel" => 3}
  """
  @spec count_by_type(integer()) :: %{String.t() => integer()}
  def count_by_type(user_id) do
    WatchHistory
    |> where(user_id: ^user_id)
    |> group_by([h], h.content_type)
    |> select([h], {h.content_type, count(h.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Adds or updates a watch history entry.
  Uses upsert - if entry exists, updates watched_at and progress fields.
  """
  @spec add(integer(), String.t(), integer(), map()) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, attrs \\ %{}) do
    %WatchHistory{}
    |> WatchHistory.changeset(
      Map.merge(attrs, %{
        user_id: user_id,
        content_type: content_type,
        content_id: content_id,
        watched_at: DateTime.utc_now()
      })
    )
    |> Repo.insert(
      on_conflict:
        {:replace, [:watched_at, :progress_seconds, :duration_seconds, :completed, :updated_at]},
      conflict_target: [:user_id, :content_type, :content_id]
    )
  end

  @doc """
  Adds a watch history entry from a map of attributes.
  Convenience function for PlayerLive.
  """
  @spec add(integer(), map()) :: {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def add(user_id, attrs) when is_map(attrs) do
    add(
      user_id,
      attrs[:content_type] || attrs["content_type"],
      attrs[:content_id] || attrs["content_id"],
      attrs
    )
  end

  @doc """
  Updates viewing progress for content.
  Marks as completed if progress reaches 90% of duration.
  """
  @spec update_progress(integer(), String.t(), integer(), integer(), integer() | nil) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def update_progress(
        user_id,
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

    add(user_id, content_type, content_id, attrs)
  end

  @doc """
  Updates watch progress from PlayerLive events.
  Handles nil duration for live streams.
  """
  @spec update_watch_progress(integer(), String.t(), integer(), number() | nil, number() | nil) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def update_watch_progress(user_id, content_type, content_id, current_time, duration) do
    duration_rounded = if duration, do: round(duration), else: nil
    update_progress(user_id, content_type, content_id, round(current_time || 0), duration_rounded)
  end

  @doc """
  Updates only the duration_seconds field.
  """
  @spec update_watch_time(integer(), String.t(), integer(), number()) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def update_watch_time(user_id, content_type, content_id, duration_seconds) do
    add(user_id, content_type, content_id, %{
      duration_seconds: round(duration_seconds)
    })
  end

  @doc """
  Removes a single watch history entry by its ID.
  """
  @spec remove(integer(), integer()) :: {integer(), nil}
  def remove(user_id, entry_id) do
    WatchHistory
    |> where(user_id: ^user_id, id: ^entry_id)
    |> Repo.delete_all()
  end

  @doc """
  Clears all watch history for a user.
  Returns {:ok, count} with number of deleted entries.
  """
  @spec clear(integer()) :: {:ok, integer()}
  def clear(user_id) do
    {count, _} =
      WatchHistory
      |> where(user_id: ^user_id)
      |> Repo.delete_all()

    {:ok, count}
  end
end
