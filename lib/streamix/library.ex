defmodule Streamix.Library do
  @moduledoc """
  Application boundary for a user's personal media library.

  This context owns favorites, watch history, playback progress, and the
  personalization refresh triggered after successful history writes.
  `Streamix.Iptv` keeps compatibility delegates while callers migrate to this
  focused boundary.
  """

  require Logger

  alias Streamix.Cache
  alias Streamix.Iptv.{Favorites, History}
  alias Streamix.Workers.UpdateUserProfileWorker

  @personalization_cache_namespace Streamix.Iptv
  @personalization_refresh_ttl :timer.minutes(1)

  # Favorites

  defdelegate list_favorites(user_id, opts \\ []), to: Favorites, as: :list
  defdelegate list_home_favorites(user_id, opts \\ []), to: Favorites, as: :list_home
  defdelegate favorite?(user_id, content_type, content_id), to: Favorites

  defdelegate count_favorites_by_type(user_id, opts \\ []),
    to: Favorites,
    as: :count_by_type

  defdelegate list_favorite_ids(user_id, content_type, content_ids \\ nil),
    to: Favorites,
    as: :list_ids

  defdelegate count_favorites(user_id, opts \\ []), to: Favorites, as: :count
  defdelegate add_favorite(user_id, attrs), to: Favorites, as: :add

  defdelegate add_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :add

  defdelegate remove_favorite(user_id, content_type, content_id),
    to: Favorites,
    as: :remove

  defdelegate toggle_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :toggle

  # Watch history and progress

  defdelegate list_watch_history(user_id, opts \\ []), to: History, as: :list
  defdelegate list_home_history(user_id, opts \\ []), to: History, as: :list_home

  defdelegate list_watch_history_for_analytics(user_id, opts \\ []),
    to: History,
    as: :list_for_analytics

  defdelegate count_watch_history_by_type(user_id, opts \\ []),
    to: History,
    as: :count_by_type

  def add_watch_history(user_id, content_type, content_id, attrs \\ %{}) do
    user_id
    |> History.add(content_type, content_id, attrs)
    |> after_history_write(user_id)
  end

  def add_to_watch_history(user_id, attrs) do
    user_id
    |> History.add(attrs)
    |> after_history_write(user_id)
  end

  def update_progress(user_id, content_type, content_id, progress, duration \\ nil) do
    user_id
    |> History.update_progress(content_type, content_id, progress, duration)
    |> after_history_write(user_id)
  end

  def update_watch_progress(user_id, content_type, content_id, current_time, duration) do
    user_id
    |> History.update_watch_progress(content_type, content_id, current_time, duration)
    |> after_history_write(user_id)
  end

  def update_watch_time(user_id, content_type, content_id, duration_seconds) do
    user_id
    |> History.update_watch_time(content_type, content_id, duration_seconds)
    |> after_history_write(user_id)
  end

  def remove_from_watch_history(user_id, entry_id) do
    result = History.remove(user_id, entry_id)

    if match?({count, _} when count > 0, result) do
      queue_personalization_refresh(user_id)
    end

    result
  end

  def clear_watch_history(user_id) do
    result = History.clear(user_id)

    if match?({:ok, count} when count > 0, result) do
      queue_personalization_refresh(user_id)
    end

    result
  end

  defdelegate get_watch_progress_map(user_id, content_type, content_ids),
    to: History,
    as: :get_progress_map

  defdelegate get_series_progress_map(user_id, series_ids), to: History

  defp after_history_write({:ok, _entry} = result, user_id) do
    queue_personalization_refresh(user_id)
    result
  end

  defp after_history_write(result, _user_id), do: result

  defp queue_personalization_refresh(user_id) do
    cache_key = {@personalization_cache_namespace, :personalization_refresh, user_id}

    Cache.fetch_local(cache_key, @personalization_refresh_ttl, fn ->
      Cache.invalidate_personalization(user_id)

      case UpdateUserProfileWorker.schedule(user_id) do
        {:ok, _job} ->
          :scheduled

        {:error, reason} ->
          Logger.warning("Failed to schedule user profile refresh",
            user_id: user_id,
            reason: inspect(reason)
          )

          :schedule_failed
      end
    end)
  end

  # User-library maintenance

  defdelegate cleanup_orphaned_user_data(user_id, opts), to: Streamix.Iptv.Sync
end
