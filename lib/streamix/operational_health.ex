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
  alias Streamix.{BuildInfo, Gindex, Iptv, Repo, Torrent}

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
      Iptv.list_public_providers()
      |> Enum.frequencies_by(&(&1.sync_status || "unknown"))

    degraded_count = Map.get(counts, "failed", 0) + Map.get(counts, "partial", 0)
    status = if degraded_count > 0, do: :degraded, else: :ok

    %{status: status, counts: counts}
  rescue
    _ -> %{status: :unavailable, counts: %{}}
  catch
    :exit, _ -> %{status: :unavailable, counts: %{}}
  end

  defp check_gindex do
    quota = Gindex.quota_status()

    state =
      cond do
        quota.remaining == 0 -> :paused
        quota.percent >= quota.warning_pct -> :warning
        true -> :available
      end

    quota
    |> Map.take([:count, :limit, :remaining, :percent])
    |> Map.put(:state, state)
    |> Map.put(:status, if(state == :paused, do: :degraded, else: :ok))
    |> maybe_put_quota_resume(state)
  rescue
    _ -> %{status: :degraded, state: :unknown}
  catch
    :exit, _ -> %{status: :degraded, state: :unknown}
  end

  defp maybe_put_quota_resume(check, :paused) do
    Map.put(check, :resumes_in_seconds, Gindex.seconds_until_quota_reset())
  end

  defp maybe_put_quota_resume(check, _state), do: check

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
