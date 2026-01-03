defmodule Streamix.Iptv.Sync.Cleanup do
  @moduledoc """
  Cleanup of orphaned user data (favorites and watch history).
  Called after sync to remove references to deleted content.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Episode, Favorite, LiveChannel, Movie, Series, WatchHistory}
  alias Streamix.Repo

  require Logger

  @doc """
  Cleans up favorites and watch history that reference deleted content.
  Called after sync to remove orphaned user data.
  """
  def cleanup_orphaned_user_data do
    Logger.info("Cleaning up orphaned favorites and watch history")

    # Clean up favorites
    {fav_live, _} = cleanup_orphaned_favorites("live_channel", LiveChannel)
    {fav_movie, _} = cleanup_orphaned_favorites("movie", Movie)
    {fav_series, _} = cleanup_orphaned_favorites("series", Series)

    # Clean up watch history
    {hist_live, _} = cleanup_orphaned_watch_history("live_channel", LiveChannel)
    {hist_movie, _} = cleanup_orphaned_watch_history("movie", Movie)
    {hist_episode, _} = cleanup_orphaned_watch_history("episode", Episode)

    total_fav = fav_live + fav_movie + fav_series
    total_hist = hist_live + hist_movie + hist_episode

    if total_fav > 0 or total_hist > 0 do
      Logger.info(
        "Removed #{total_fav} orphaned favorites, #{total_hist} orphaned history entries"
      )
    end

    {:ok, %{favorites: total_fav, watch_history: total_hist}}
  end

  defp cleanup_orphaned_favorites(content_type, schema) do
    Favorite
    |> where([f], f.content_type == ^content_type)
    |> where([f], f.content_id not in subquery(from(s in schema, select: s.id)))
    |> Repo.delete_all()
  end

  defp cleanup_orphaned_watch_history(content_type, schema) do
    WatchHistory
    |> where([w], w.content_type == ^content_type)
    |> where([w], w.content_id not in subquery(from(s in schema, select: s.id)))
    |> Repo.delete_all()
  end
end
