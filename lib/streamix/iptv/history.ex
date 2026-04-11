defmodule Streamix.Iptv.History do
  @moduledoc """
  Watch history management backed by concrete playable content foreign keys.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.WatchHistory
  alias Streamix.Library.ContentRef
  alias Streamix.Repo

  @content_types ContentRef.history_types()
  @preloads [:live_channel, :movie, :episode]

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
      |> preload(^@preloads)

    query = maybe_filter_by_type(query, content_type)

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Enum.map(&ContentRef.decorate/1)
  end

  @doc """
  Counts watch history grouped by content type for a user.
  Returns a map like %{"movie" => 10, "episode" => 15, "live_channel" => 3}
  """
  @spec count_by_type(integer()) :: %{String.t() => integer()}
  def count_by_type(user_id) do
    @content_types
    |> Enum.reduce(%{}, fn type, acc ->
      count =
        WatchHistory
        |> where(user_id: ^user_id)
        |> maybe_filter_by_type(type)
        |> Repo.aggregate(:count)

      if count > 0, do: Map.put(acc, type, count), else: acc
    end)
  end

  @doc """
  Adds or updates a watch history entry.
  Uses upsert - if entry exists, updates watched_at and progress fields.
  """
  @spec add(integer(), String.t(), integer(), map()) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, attrs \\ %{}) do
    case ContentRef.resolve_target_attrs(content_type, content_id, @content_types) do
      {:ok, target_attrs} ->
        {target_field, normalized_id} = Enum.at(target_attrs, 0)

        query =
          WatchHistory
          |> where(user_id: ^user_id)
          |> where([w], field(w, ^target_field) == ^normalized_id)

        attrs =
          attrs
          |> Map.merge(target_attrs)
          |> Map.put(:user_id, user_id)
          |> Map.put(:watched_at, DateTime.utc_now() |> DateTime.truncate(:second))

        case Repo.one(query) do
          nil ->
            %WatchHistory{}
            |> WatchHistory.changeset(attrs)
            |> Repo.insert()
            |> maybe_decorate()

          %WatchHistory{} = entry ->
            entry
            |> WatchHistory.changeset(attrs)
            |> Repo.update()
            |> maybe_decorate()
        end

      {:error, :invalid_content_type} ->
        {:error,
         Changeset.change(%WatchHistory{})
         |> Changeset.add_error(:content_type, "is invalid")}

      {:error, :invalid_content_id} ->
        {:error,
         Changeset.change(%WatchHistory{})
         |> Changeset.add_error(:content_id, "is invalid")}
    end
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

  @doc """
  Returns a map of content_id => progress (0.0..1.0) for the given content IDs.
  Used for showing progress bars on content cards.
  """
  @spec get_progress_map(integer(), String.t(), [integer()]) :: %{integer() => float()}
  def get_progress_map(_user_id, _content_type, []), do: %{}

  def get_progress_map(user_id, content_type, content_ids) do
    case content_field(content_type) do
      {:ok, field} ->
        WatchHistory
        |> where([w], w.user_id == ^user_id and field(w, ^field) in ^content_ids)
        |> where([w], w.duration_seconds > 0 and w.progress_seconds > 0)
        |> select([w], {field(w, ^field), w.progress_seconds, w.duration_seconds})
        |> Repo.all()
        |> Map.new(fn {id, progress, duration} ->
          {id, Float.round(progress / duration, 2)}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, content_type) do
    case content_field(content_type) do
      {:ok, field} ->
        where(query, [w], not is_nil(field(w, ^field)))

      {:error, _reason} ->
        where(query, [w], false)
    end
  end

  defp content_field(content_type) do
    case ContentRef.target_field(content_type) do
      field when field in [:live_channel_id, :movie_id, :episode_id] -> {:ok, field}
      _ -> {:error, :invalid_content_type}
    end
  end

  defp maybe_decorate({:ok, entry}) do
    entry
    |> Repo.preload(@preloads)
    |> ContentRef.decorate()
    |> then(&{:ok, &1})
  end

  defp maybe_decorate({:error, changeset}), do: {:error, changeset}
end
