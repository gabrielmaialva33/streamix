defmodule Streamix.Operations do
  @moduledoc """
  Compact operational read model for the admin dashboard.

  Database work stays synchronous in the LiveView process so tests and
  SQL Sandbox ownership remain deterministic. Network/ETS probes are
  exposed separately and can run through `start_async/3`.
  """

  import Ecto.Query

  alias Streamix.{BuildInfo, Gindex, Providers, Qoe, Repo, Torrent}

  @event_table :streamix_operations_events

  def setup do
    if :ets.whereis(@event_table) == :undefined do
      :ets.new(@event_table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc "Fast DB-only snapshot. Safe to call from the LiveView process."
  def initial_summary do
    %{
      revision: release_revision(),
      oban: oban_summary(),
      qoe: Qoe.summary(),
      providers: %{status: :unknown, counts: %{}},
      torrent: %{status: :unknown, active_torrents: 0, message: "carregando"},
      gindex: %{quota: %{count: 0, limit: 0, percent: 0}, telemetry: %{}, endpoints: []},
      events: event_summary()
    }
  end

  @doc "Network and runtime snapshot intended for a LiveView async task."
  def runtime_summary do
    %{
      revision: release_revision(),
      providers: Providers.cached_provider_health_summary(),
      torrent: Torrent.health(),
      gindex: Gindex.operations_status(),
      events: event_summary()
    }
  end

  def record_event(kind, value) when is_atom(kind) do
    setup()
    key = {kind, normalize_value(value)}
    :ets.update_counter(@event_table, key, {2, 1}, {key, 0})
    :ok
  end

  defp event_summary do
    setup()

    @event_table
    |> :ets.tab2list()
    |> Enum.reduce(%{torrent_states: %{}, playback_failures: %{}}, fn
      {{:torrent_state, state}, count}, acc ->
        put_in(acc, [:torrent_states, state], count)

      {{:playback_failure, stage}, count}, acc ->
        put_in(acc, [:playback_failures, stage], count)

      _, acc ->
        acc
    end)
  end

  defp oban_summary do
    Oban.Job
    |> group_by([job], job.state)
    |> select([job], {job.state, count(job.id)})
    |> Repo.all()
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp release_revision do
    case BuildInfo.revision() do
      "unknown" -> "development"
      revision -> String.slice(revision, 0, 12)
    end
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp normalize_value(_value), do: "unknown"
end
