defmodule Streamix.Iptv.ProviderHealthMonitor do
  @moduledoc """
  Keeps a warm copy of `Streamix.Iptv.ProviderHealth.overall_status/0`
  in ETS so LiveView mounts can read it in microseconds.

  The reason this exists: the probe in `ProviderHealth` makes an HTTP
  call with a multi-second timeout when the upstream is misbehaving.
  Doing that probe inline on every LV mount — which is what the
  earlier version did, even with a 30s ConCache TTL — meant the first
  mount per window paid a 4-second bill, and concurrent mounts all
  queued on the same cache-fill call. Users saw this as "the home
  takes longer to load now that the banner exists".

  Moving the probe into a GenServer that refreshes on its own timer
  severs the mount path from the network entirely:

    * ETS lookup in `get/0` is <10 µs, never blocks
    * If the monitor hasn't probed yet (fresh boot), `get/0` returns
      `:unknown` so the banner hides — better than blocking the
      user's first paint
    * Refresh happens every #{30}s in the monitor's own process, so
      status updates lag real-world reality by at most that
  """

  use GenServer

  alias Streamix.Iptv.ProviderHealth

  require Logger

  @table_name :provider_health_cache
  @cache_key :latest
  @refresh_interval :timer.seconds(30)
  # First probe waits one tick so the supervisor boot path isn't held
  # hostage if the upstream is slow to respond on cold start.
  @initial_delay :timer.seconds(1)

  # --- Public API ---

  @doc """
  Starts the monitor. Wire into the supervision tree; there's only
  ever one process per node.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the last-known overall status. Never blocks — if the
  monitor hasn't published its first sample yet, returns a neutral
  `:unknown` with `show_banner?: false`.
  """
  @spec get() :: %{status: atom(), counts: map(), show_banner?: boolean()}
  def get do
    case :ets.lookup(@table_name, @cache_key) do
      [{@cache_key, value}] -> value
      [] -> default_sample()
    end
  rescue
    # ETS table hasn't been created yet (called before the monitor
    # starts). Return the same neutral default.
    ArgumentError -> default_sample()
  end

  @doc """
  Forces an immediate refresh. Non-blocking — the cast returns as
  soon as the refresh is enqueued.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@table_name, {@cache_key, default_sample()})
    Process.send_after(self(), :refresh, @initial_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh()
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  defp do_refresh do
    sample = build_sample()
    :ets.insert(@table_name, {@cache_key, sample})
  rescue
    e ->
      # An individual refresh failure shouldn't crash the monitor —
      # keep the last-known-good sample.
      Logger.warning("[ProviderHealthMonitor] refresh failed: #{Exception.message(e)}")
  end

  defp build_sample do
    %{status: status, counts: counts} = ProviderHealth.overall_status()

    %{
      status: status,
      counts: counts,
      show_banner?: status in [:degraded, :unhealthy]
    }
  end

  defp default_sample do
    %{status: :unknown, counts: %{}, show_banner?: false}
  end
end
