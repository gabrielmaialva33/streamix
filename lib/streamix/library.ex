defmodule Streamix.Library do
  @moduledoc """
  User-owned library data such as favorites and watch history.

  This context isolates user state from the broader IPTV catalog/playback
  concerns while preserving the existing public API shape.
  """

  alias Streamix.Iptv.{Favorites, History}

  defdelegate list_favorites(user_id, opts \\ []), to: Favorites, as: :list
  defdelegate list_home_favorites(user_id, opts \\ []), to: Favorites, as: :list_home
  defdelegate favorite?(user_id, content_type, content_id), to: Favorites
  defdelegate count_favorites_by_type(user_id), to: Favorites, as: :count_by_type

  defdelegate list_favorite_ids(user_id, content_type, content_ids \\ nil),
    to: Favorites,
    as: :list_ids

  defdelegate count_favorites(user_id), to: Favorites, as: :count
  defdelegate add_favorite(user_id, attrs), to: Favorites, as: :add

  defdelegate add_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :add

  defdelegate remove_favorite(user_id, content_type, content_id), to: Favorites, as: :remove

  defdelegate toggle_favorite(user_id, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :toggle

  defdelegate list_watch_history(user_id, opts \\ []), to: History, as: :list
  defdelegate list_home_history(user_id, opts \\ []), to: History, as: :list_home
  defdelegate count_watch_history_by_type(user_id), to: History, as: :count_by_type

  defdelegate add_watch_history(user_id, content_type, content_id, attrs \\ %{}),
    to: History,
    as: :add

  defdelegate add_to_watch_history(user_id, attrs), to: History, as: :add

  defdelegate update_progress(user_id, content_type, content_id, progress, duration \\ nil),
    to: History

  defdelegate update_watch_progress(user_id, content_type, content_id, current_time, duration),
    to: History

  defdelegate update_watch_time(user_id, content_type, content_id, duration_seconds), to: History
  defdelegate remove_from_watch_history(user_id, entry_id), to: History, as: :remove
  defdelegate clear_watch_history(user_id), to: History, as: :clear

  defdelegate get_watch_progress_map(user_id, content_type, content_ids),
    to: History,
    as: :get_progress_map

  defdelegate get_series_progress_map(user_id, series_ids),
    to: History
end
