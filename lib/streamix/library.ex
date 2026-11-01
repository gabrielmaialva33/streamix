defmodule Streamix.Library do
  @moduledoc """
  Application boundary for a user's personal media library: favorites, watch
  history and playback progress.

  The library is end-to-end private from the operator. Rows are sealed with a
  per-user key that only the user's password or a live session secret held
  by their client can open (see `Streamix.Library.Keyring` and
  docs/privacy.md), so the database, backups, logs and caches never reveal
  what a user watched.

  Every library operation therefore takes the caller's unlocked
  `Streamix.Library.Key` — `scope.library_key` on the web, the bearer token's
  key on the API — instead of a bare user id. A key carries its user id.
  `Streamix.Iptv` keeps compatibility delegates while callers migrate to
  this focused boundary.
  """

  alias Streamix.Cache
  alias Streamix.Iptv.{Favorites, History}
  alias Streamix.Library.{Key, Keyring, LegacyImport}

  @personalization_cache_namespace Streamix.Iptv
  @personalization_refresh_ttl :timer.minutes(1)

  # Keys and sessions

  @doc """
  Unlocks the user's library with their verified password at login, creating
  the key on first use and sealing any plaintext rows left from before the
  library was encrypted.

  `{:error, :locked}` when a stored key does not open with this password; the
  library is left as it is.
  """
  @spec unlock(%{:id => integer(), optional(atom()) => any()}, String.t()) ::
          {:ok, Key.t()} | {:error, :locked}
  def unlock(%{id: user_id}, password) when is_binary(password) do
    with {:ok, key} <- Keyring.unlock(user_id, password) do
      :ok = LegacyImport.run(key)
      {:ok, key}
    end
  end

  @doc """
  Wraps `key` for a new session. Returns `{client_secret, sealed}`: the
  secret goes to the client only, the sealed blob is stored with the session.
  """
  defdelegate seal_session(key), to: Keyring

  @doc "Unlocks the library from a session's stored wrap and the client's secret."
  defdelegate open_session(user_id, client_secret, sealed), to: Keyring

  @doc "Byte size of a session's client secret."
  defdelegate session_secret_bytes(), to: Keyring

  @doc """
  Re-wraps the user's key when they change their password, knowing the
  current one. History and favorites survive.
  """
  @spec change_password(integer(), String.t(), String.t()) :: :ok | {:error, :locked}
  def change_password(user_id, current_password, new_password) do
    with {:ok, _key} <- Keyring.rewrap(user_id, current_password, new_password), do: :ok
  end

  @doc """
  Discards the user's key and everything sealed under it. Used when the
  password is replaced without the current one: nobody can open the old
  library anymore, so its rows are only noise.
  """
  @spec forget(integer()) :: :ok
  def forget(user_id) when is_integer(user_id) do
    forget_rows(user_id)
    Keyring.forget(user_id)
  end

  @doc "Deletes legacy plaintext rows that were never sealed. See `LegacyImport.purge/0`."
  defdelegate purge_legacy_plaintext(), to: LegacyImport, as: :purge

  # Favorites

  defdelegate list_favorites(key, opts \\ []), to: Favorites, as: :list
  defdelegate list_home_favorites(key, opts \\ []), to: Favorites, as: :list_home
  defdelegate favorite?(key, content_type, content_id), to: Favorites

  defdelegate count_favorites_by_type(key, opts \\ []),
    to: Favorites,
    as: :count_by_type

  defdelegate list_favorite_ids(key, content_type, content_ids \\ nil),
    to: Favorites,
    as: :list_ids

  defdelegate count_favorites(key, opts \\ []), to: Favorites, as: :count
  defdelegate add_favorite(key, attrs), to: Favorites, as: :add

  defdelegate add_favorite(key, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :add

  defdelegate remove_favorite(key, content_type, content_id),
    to: Favorites,
    as: :remove

  defdelegate toggle_favorite(key, content_type, content_id, attrs \\ %{}),
    to: Favorites,
    as: :toggle

  # Watch history and progress

  defdelegate list_watch_history(key, opts \\ []), to: History, as: :list
  defdelegate list_home_history(key, opts \\ []), to: History, as: :list_home

  defdelegate list_watch_history_for_analytics(key, opts \\ []),
    to: History,
    as: :list_for_analytics

  defdelegate count_watch_history_by_type(key, opts \\ []),
    to: History,
    as: :count_by_type

  def add_watch_history(key, content_type, content_id, attrs \\ %{}) do
    key
    |> History.add(content_type, content_id, attrs)
    |> after_history_write(key)
  end

  def add_to_watch_history(key, attrs) do
    key
    |> History.add(attrs)
    |> after_history_write(key)
  end

  def update_progress(key, content_type, content_id, progress, duration \\ nil) do
    key
    |> History.update_progress(content_type, content_id, progress, duration)
    |> after_history_write(key)
  end

  def update_watch_progress(key, content_type, content_id, current_time, duration) do
    key
    |> History.update_watch_progress(content_type, content_id, current_time, duration)
    |> after_history_write(key)
  end

  def update_watch_time(key, content_type, content_id, duration_seconds) do
    key
    |> History.update_watch_time(content_type, content_id, duration_seconds)
    |> after_history_write(key)
  end

  def remove_from_watch_history(%Key{} = key, entry_id) do
    result = History.remove(key, entry_id)

    if match?({count, _} when count > 0, result) do
      refresh_personalization(key.user_id)
    end

    result
  end

  def clear_watch_history(%Key{} = key) do
    result = History.clear(key)

    if match?({:ok, count} when count > 0, result) do
      refresh_personalization(key.user_id)
    end

    result
  end

  defdelegate get_watch_progress_map(key, content_type, content_ids),
    to: History,
    as: :get_progress_map

  defdelegate get_series_progress_map(key, series_ids), to: History

  defdelegate latest_series_progress(key, series_ids), to: History

  defp after_history_write({:ok, _entry} = result, %Key{user_id: user_id}) do
    refresh_personalization(user_id)
    result
  end

  defp after_history_write(result, _key), do: result

  # Personalization is derived from the history inside the user's session and
  # only cached in this node's memory (see Streamix.AI.UserAnalytics), so a
  # write just drops the stale copy — at most once a minute, because the
  # player reports progress every few seconds.
  defp refresh_personalization(user_id) do
    cache_key = {@personalization_cache_namespace, :personalization_refresh, user_id}

    Cache.fetch_local(cache_key, @personalization_refresh_ttl, fn ->
      Cache.invalidate_personalization(user_id)
      :invalidated
    end)
  end

  defp forget_rows(user_id) do
    {:ok, _} = History.clear(user_id)
    {:ok, _} = Favorites.clear(user_id)
    Cache.invalidate_personalization(user_id)
    :ok
  end

  # User-library maintenance

  defdelegate cleanup_orphaned_user_data(provider_id, opts), to: Streamix.Iptv.Sync
end
