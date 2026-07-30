defmodule Streamix.Torrent.StatsRefresher do
  @moduledoc false

  require Logger

  alias Streamix.Repo

  @advisory_lock_key 8_380_019_912_025
  @view_name "public.torrent_movie_stats"
  @refresh "REFRESH MATERIALIZED VIEW torrent_movie_stats"
  @refresh_concurrently "REFRESH MATERIALIZED VIEW CONCURRENTLY torrent_movie_stats"
  @refresh_timeout :timer.minutes(5)

  @spec refresh(keyword()) :: :ok | {:error, term()}
  def refresh(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.checkout(fn ->
      case acquire_lock(repo) do
        :acquired ->
          try do
            refresh_locked(repo)
          after
            release_lock(repo)
          end

        :busy ->
          Logger.debug("[Torrent] stats refresh already running; waiting for it to finish")
          await_existing_refresh(repo)

        {:error, reason} ->
          {:error, {:torrent_stats_refresh_failed, reason}}
      end
    end)
  end

  defp acquire_lock(repo) do
    case repo.query("SELECT pg_try_advisory_lock($1)", [@advisory_lock_key]) do
      {:ok, %{rows: [[true]]}} -> :acquired
      {:ok, %{rows: [[false]]}} -> :busy
      {:ok, result} -> {:error, {:unexpected_advisory_lock_result, result.rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_lock(repo) do
    case repo.query("SELECT pg_advisory_unlock($1)", [@advisory_lock_key]) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      unexpected ->
        Logger.error(
          "[Torrent] failed to release stats refresh advisory lock " <>
            "result=#{inspect(unexpected, limit: 10, printable_limit: 500)}"
        )
    end
  end

  defp await_existing_refresh(repo) do
    case repo.query(
           "SELECT pg_advisory_lock($1)",
           [@advisory_lock_key],
           timeout: @refresh_timeout
         ) do
      {:ok, _result} ->
        try do
          :ok
        after
          release_lock(repo)
        end

      {:error, reason} ->
        {:error, {:torrent_stats_refresh_join_failed, reason}}
    end
  end

  defp refresh_locked(repo) do
    if repo.in_transaction?() do
      run_refresh(repo, @refresh)
    else
      case materialized_view_populated(repo) do
        {:ok, true} -> run_refresh(repo, @refresh_concurrently)
        {:ok, false} -> run_refresh(repo, @refresh)
        {:error, reason} -> {:error, {:torrent_stats_refresh_failed, reason}}
      end
    end
  end

  defp run_refresh(repo, sql) do
    case repo.query(sql, [], timeout: @refresh_timeout) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:torrent_stats_refresh_failed, reason}}
    end
  end

  defp materialized_view_populated(repo) do
    case repo.query(
           "SELECT relispopulated FROM pg_class WHERE oid = to_regclass($1::text)",
           [@view_name]
         ) do
      {:ok, %{rows: [[populated?]]}} when is_boolean(populated?) ->
        {:ok, populated?}

      {:ok, %{rows: []}} ->
        {:ok, false}

      {:error, reason} ->
        {:error, {:materialized_view_inspection_failed, @view_name, reason}}
    end
  end
end
