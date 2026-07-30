defmodule Streamix.Torrent.StatsRefresherTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.StatsRefresher

  defmodule RepoStub do
    def checkout(fun), do: fun.()
    def in_transaction?, do: Process.get(:stats_refresher_in_transaction, false)

    def query(sql, params \\ [], opts \\ []) do
      send(self(), {:query, sql, params, opts})

      cond do
        String.contains?(sql, "pg_try_advisory_lock") ->
          {:ok, %{rows: [[Process.get(:stats_refresher_lock_available, true)]]}}

        String.contains?(sql, "pg_advisory_unlock") ->
          {:ok, %{rows: [[true]]}}

        String.contains?(sql, "pg_advisory_lock") ->
          Process.get(:stats_refresher_wait_result, {:ok, %{rows: [[nil]]}})

        String.contains?(sql, "relispopulated") ->
          {:ok, %{rows: [[Process.get(:stats_refresher_populated, true)]]}}

        String.starts_with?(sql, "REFRESH MATERIALIZED VIEW") ->
          Process.get(:stats_refresher_refresh_result, {:ok, %{rows: []}})
      end
    end
  end

  setup do
    on_exit(fn ->
      for key <- [
            :stats_refresher_in_transaction,
            :stats_refresher_lock_available,
            :stats_refresher_populated,
            :stats_refresher_refresh_result,
            :stats_refresher_wait_result
          ] do
        Process.delete(key)
      end
    end)
  end

  test "uses a concurrent refresh for an already-populated view" do
    assert :ok = StatsRefresher.refresh(repo: RepoStub)

    queries = drain_queries()

    assert Enum.any?(queries, fn
             {sql, [], [timeout: 300_000]} ->
               sql == "REFRESH MATERIALIZED VIEW CONCURRENTLY torrent_movie_stats"

             _other ->
               false
           end)

    assert List.last(queries) ==
             {"SELECT pg_advisory_unlock($1)", [8_380_019_912_025], []}
  end

  test "uses a blocking refresh only for the first population" do
    Process.put(:stats_refresher_populated, false)

    assert :ok = StatsRefresher.refresh(repo: RepoStub)

    assert {"REFRESH MATERIALIZED VIEW torrent_movie_stats", [], timeout: 300_000} in drain_queries()
  end

  test "uses the transaction-safe path inside the SQL sandbox" do
    Process.put(:stats_refresher_in_transaction, true)

    assert :ok = StatsRefresher.refresh(repo: RepoStub)

    queries = drain_queries()
    assert {"REFRESH MATERIALIZED VIEW torrent_movie_stats", [], timeout: 300_000} in queries

    refute Enum.any?(queries, fn {sql, _params, _opts} ->
             String.contains?(sql, "relispopulated")
           end)
  end

  test "waits for an in-flight refresh before reporting success" do
    Process.put(:stats_refresher_lock_available, false)

    assert :ok = StatsRefresher.refresh(repo: RepoStub)

    assert drain_queries() == [
             {"SELECT pg_try_advisory_lock($1)", [8_380_019_912_025], []},
             {"SELECT pg_advisory_lock($1)", [8_380_019_912_025], timeout: 300_000},
             {"SELECT pg_advisory_unlock($1)", [8_380_019_912_025], []}
           ]
  end

  test "does not clear callers to proceed when joining a refresh times out" do
    Process.put(:stats_refresher_lock_available, false)
    Process.put(:stats_refresher_wait_result, {:error, :timeout})

    assert {:error, {:torrent_stats_refresh_join_failed, :timeout}} =
             StatsRefresher.refresh(repo: RepoStub)

    refute Enum.any?(drain_queries(), fn {sql, _params, _opts} ->
             String.contains?(sql, "pg_advisory_unlock")
           end)
  end

  test "releases the advisory lock when refresh fails" do
    Process.put(:stats_refresher_refresh_result, {:error, :database_unavailable})

    assert {:error, {:torrent_stats_refresh_failed, :database_unavailable}} =
             StatsRefresher.refresh(repo: RepoStub)

    assert List.last(drain_queries()) ==
             {"SELECT pg_advisory_unlock($1)", [8_380_019_912_025], []}
  end

  defp drain_queries(acc \\ []) do
    receive do
      {:query, sql, params, opts} -> drain_queries([{sql, params, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
