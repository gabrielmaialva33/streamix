defmodule Streamix.OperationalHealth do
  @moduledoc """
  Readiness snapshot for required infrastructure and optional subsystems.

  `/api/health` remains a shallow liveness probe so Docker doesn't restart a
  healthy BEAM because an upstream is down. This module powers
  `/api/health/ready`, where required dependency failures return
  `:unavailable` and optional feature failures return `:degraded`.
  """

  alias Ecto.Adapters.SQL
  alias Streamix.AI.{Embeddings, Qdrant, SemanticSearch}
  alias Streamix.{BuildInfo, Gindex, Providers, Repo, Torrent}

  @check_timeout :timer.seconds(6)
  @required_checks [:database, :redis]

  @doc """
  Returns a bounded, credential-free operational snapshot.
  """
  def snapshot do
    checks =
      [
        database: &check_database/0,
        redis: &check_redis/0,
        providers: &check_providers/0,
        gindex: &check_gindex/0,
        semantic_search: &check_semantic_search/0,
        torrent: &check_torrent/0
      ]
      |> run_checks()

    %{
      status: overall_status(checks),
      release: BuildInfo.snapshot(),
      checks: checks,
      timestamp: DateTime.utc_now()
    }
  end

  defp run_checks(checks) do
    results =
      Task.async_stream(
        checks,
        fn {name, check} -> {name, check.()} end,
        ordered: true,
        timeout: @check_timeout,
        on_timeout: :kill_task
      )

    checks
    |> Enum.zip(results)
    |> Map.new(fn
      {{name, _check}, {:ok, {result_name, result}}} when name == result_name ->
        {name, result}

      {{name, _check}, {:exit, _reason}} ->
        {name, timed_out_check(name)}
    end)
  end

  defp check_database do
    case SQL.query(Repo, "SELECT max(version)::text FROM schema_migrations", [], timeout: 2_000) do
      {:ok, %{rows: [[migration]]}} -> %{status: :ok, migration: migration}
      {:error, _reason} -> %{status: :unavailable}
    end
  rescue
    _ -> %{status: :unavailable}
  catch
    :exit, _ -> %{status: :unavailable}
  end

  defp check_redis do
    case Redix.command(:streamix_redis, ["PING"], timeout: 2_000) do
      {:ok, "PONG"} -> %{status: :ok}
      {:ok, _response} -> %{status: :degraded}
      {:error, _reason} -> %{status: :unavailable}
    end
  rescue
    _ -> %{status: :unavailable}
  catch
    :exit, _ -> %{status: :unavailable}
  end

  defp check_providers do
    counts =
      Providers.list_public_providers()
      |> Enum.frequencies_by(&(&1.sync_status || "unknown"))

    degraded_count =
      Enum.sum(
        for status <- ~w(failed partial paused_quota paused_upstream),
            do: Map.get(counts, status, 0)
      )

    status = if degraded_count > 0, do: :degraded, else: :ok

    %{status: status, counts: counts}
  rescue
    _ -> %{status: :unavailable, counts: %{}}
  catch
    :exit, _ -> %{status: :unavailable, counts: %{}}
  end

  defp check_gindex do
    quota = Gindex.quota_status()
    upstream = Gindex.upstream_status()
    sync_state = gindex_sync_state(quota, upstream.sync)
    playback_state = gindex_playback_state(quota, upstream.playback)
    state = gindex_state(sync_state, playback_state, quota)

    quota
    |> Map.take([
      :count,
      :limit,
      :remaining,
      :percent,
      :background_limit,
      :background_remaining,
      :background_percent,
      :playback_reserve
    ])
    |> Map.put(:state, state)
    |> Map.put(:sync_state, sync_state)
    |> Map.put(:playback_state, playback_state)
    |> Map.put(:upstream, upstream)
    |> Map.put(:status, if(state == :available, do: :ok, else: :degraded))
    |> maybe_put_quota_resume(quota)
  rescue
    _ -> %{status: :degraded, state: :unknown}
  catch
    :exit, _ -> %{status: :degraded, state: :unknown}
  end

  defp gindex_sync_state(%{background_remaining: 0}, _upstream), do: :paused
  defp gindex_sync_state(_quota, %{state: :available}), do: :available
  defp gindex_sync_state(_quota, _upstream), do: :unavailable

  defp gindex_playback_state(%{remaining: 0}, _upstream), do: :unavailable
  defp gindex_playback_state(_quota, %{state: :available}), do: :available
  defp gindex_playback_state(_quota, _upstream), do: :unavailable

  defp gindex_state(_sync_state, :unavailable, _quota), do: :playback_unavailable
  defp gindex_state(:paused, :available, _quota), do: :background_paused
  defp gindex_state(:unavailable, :available, _quota), do: :background_unavailable

  defp gindex_state(:available, :available, quota) do
    if quota.percent >= quota.warning_pct or quota.background_percent >= quota.warning_pct,
      do: :warning,
      else: :available
  end

  defp maybe_put_quota_resume(check, %{background_remaining: 0}) do
    Map.put(check, :resumes_in_seconds, Gindex.seconds_until_quota_reset())
  end

  defp maybe_put_quota_resume(check, _quota), do: check

  defp check_semantic_search do
    if Embeddings.enabled?() do
      semantic_search_status()
    else
      %{status: :disabled}
    end
  rescue
    _ -> %{status: :degraded}
  catch
    :exit, _ -> %{status: :degraded}
  end

  defp semantic_search_status do
    case Qdrant.health_check() do
      {:ok, :healthy} ->
        {:ok, collections} = SemanticSearch.stats()

        missing =
          for {name, %{status: "not_found"}} <- collections,
              do: name

        %{
          status: if(missing == [], do: :ok, else: :degraded),
          missing_collections: missing,
          collections: collections
        }

      {:error, :disabled} ->
        %{status: :disabled}

      {:error, _reason} ->
        %{status: :degraded}
    end
  end

  defp check_torrent do
    case Torrent.health() do
      %{status: :healthy, active_torrents: count} ->
        %{status: :ok, active_torrents: count}

      %{status: :disabled} ->
        %{status: :disabled, active_torrents: 0}

      %{status: :unhealthy} ->
        %{status: :degraded, active_torrents: 0}
    end
  rescue
    _ -> %{status: :degraded, active_torrents: 0}
  catch
    :exit, _ -> %{status: :degraded, active_torrents: 0}
  end

  defp timed_out_check(name) when name in @required_checks, do: %{status: :unavailable}
  defp timed_out_check(_name), do: %{status: :degraded}

  defp overall_status(checks) do
    statuses = Enum.map(checks, fn {_name, check} -> check.status end)

    cond do
      :unavailable in statuses -> :unavailable
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end
end
