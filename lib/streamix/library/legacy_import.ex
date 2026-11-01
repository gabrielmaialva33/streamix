defmodule Streamix.Library.LegacyImport do
  @moduledoc """
  Seals the plaintext history and favorites a user had before the library
  was encrypted.

  Sealing needs the user's key, which only exists once they log in, so each
  user's rows in the plaintext `watch_progress` and `favorites` tables are
  sealed into `sealed_watch_progress` and `sealed_favorites` at their next
  login and then deleted. Rows of users who never come back stay readable
  until an operator runs `purge/0`.

  The plaintext tables stay in the schema for one release, so an image
  rollback still finds them (see the SealPersonalLibrary migration).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Streamix.Iptv.{Favorite, Favorites, History, WatchProgress}
  alias Streamix.Library.Key
  alias Streamix.Repo

  @doc "Moves the user's legacy rows into the sealed tables. Idempotent."
  @spec run(Key.t()) :: :ok
  def run(%Key{} = key) do
    {:ok, _} =
      Repo.transact(fn ->
        progress = import_progress(key)
        favorites = import_favorites(key)
        {:ok, {progress, favorites}}
      end)

    :ok
  end

  @doc """
  Deletes every legacy plaintext row that was never imported, returning how
  many were removed. Users who had not logged in since the upgrade lose that
  history; run it once the remaining rows are no longer worth the exposure.
  """
  @spec purge() :: %{watch_progress: non_neg_integer(), favorites: non_neg_integer()}
  def purge do
    {progress, _} = Repo.delete_all("watch_progress")
    {favorites, _} = Repo.delete_all("favorites")
    %{watch_progress: progress, favorites: favorites}
  end

  defp import_progress(%Key{user_id: user_id} = key) do
    rows =
      from(progress in "watch_progress",
        join: catalog_item in "catalog_items",
        on: catalog_item.id == progress.catalog_item_id,
        left_join: episode in "episodes",
        on: episode.catalog_item_id == progress.catalog_item_id,
        left_join: season in "seasons",
        on: season.id == episode.season_id,
        where: progress.user_id == ^user_id,
        select: %{
          catalog_item_id: progress.catalog_item_id,
          content_type: catalog_item.content_type,
          series_id: season.series_id,
          progress_seconds: progress.progress_seconds,
          duration_seconds: progress.duration_seconds,
          completed: progress.completed,
          last_watched_at: type(progress.last_watched_at, :utc_datetime)
        }
      )
      |> Repo.all()

    sealed = Enum.map(rows, &History.sealed_row(key, &1))

    insert_chunks(WatchProgress, sealed)
    delete_legacy("watch_progress", user_id, length(rows))
  end

  defp import_favorites(%Key{user_id: user_id} = key) do
    rows =
      from(favorite in "favorites",
        join: catalog_item in "catalog_items",
        on: catalog_item.id == favorite.catalog_item_id,
        where: favorite.user_id == ^user_id,
        select: %{
          catalog_item_id: favorite.catalog_item_id,
          content_type: catalog_item.content_type,
          inserted_at: type(favorite.inserted_at, :utc_datetime)
        }
      )
      |> Repo.all()

    sealed = Enum.map(rows, &Favorites.sealed_row(key, &1))

    insert_chunks(Favorite, sealed)
    delete_legacy("favorites", user_id, length(rows))
  end

  defp insert_chunks(schema, rows) do
    rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(schema, &1, on_conflict: :nothing))
  end

  # Rows whose catalog item is already gone could not be sealed and carry
  # nothing worth keeping; they go too.
  defp delete_legacy(table, user_id, imported) do
    {deleted, _} =
      from(row in table, where: field(row, :user_id) == ^user_id)
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info("[Library] sealed #{imported} plaintext #{table} rows", user_id: user_id)
    end

    imported
  end
end
