defmodule Streamix.Iptv.Streaming.ProviderRuntime do
  @moduledoc """
  Node-local runtime state for provider health and connection capacity.

  Xtream's `max_connections` is an upstream account limit, not an HTTP pool
  setting. Live streams honor that reported limit, while VOD streams use a
  separately configured ceiling. Every live/VOD stream acquires a lease before
  opening the upstream socket. Leases are tied to the caller process and are
  automatically reclaimed on `:DOWN`, including abrupt client disconnects.

  This process is intentionally node-local. A multi-node deployment must put a
  distributed admission layer in front of it before sharing one Xtream account.
  """

  use GenServer

  alias Streamix.Iptv.ProviderCapabilities

  @dimensions [:control, :live, :vod]
  @terminal_failures [:authentication_failed, :account_expired, :account_disabled]
  @ewma_alpha 0.3
  @default_vod_connection_ceiling 4

  @type dimension :: :control | :live | :vod
  @type status :: :healthy | :degraded | :unhealthy | :unknown
  @type lease :: reference()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stores the latest sanitized capabilities for a provider."
  @spec put_capabilities(integer(), ProviderCapabilities.t()) :: :ok
  def put_capabilities(provider_id, %ProviderCapabilities{} = capabilities) do
    safe_call({:put_capabilities, provider_id, capabilities}, :ok)
  end

  @doc "Records a successful request for one provider traffic dimension."
  @spec record_success(integer() | nil, dimension(), non_neg_integer() | nil) :: :ok
  def record_success(provider_id, dimension, latency_ms \\ nil)

  def record_success(nil, _dimension, _latency_ms), do: :ok

  def record_success(provider_id, dimension, latency_ms) when dimension in @dimensions do
    safe_call({:record_success, provider_id, dimension, latency_ms}, :ok)
  end

  @doc "Records a provider-impacting failure for one traffic dimension."
  @spec record_failure(integer() | nil, dimension(), term()) :: :ok
  def record_failure(nil, _dimension, _reason), do: :ok

  def record_failure(provider_id, dimension, reason) when dimension in @dimensions do
    safe_call({:record_failure, provider_id, dimension, sanitize_reason(reason)}, :ok)
  end

  @doc "Acquires one upstream stream slot for the owner process."
  @spec acquire(integer() | nil, :live | :vod, pid()) ::
          {:ok, lease() | :untracked} | {:error, :capacity_exhausted}
  def acquire(provider_id, traffic_class, owner \\ self())

  def acquire(nil, _traffic_class, _owner), do: {:ok, :untracked}

  def acquire(provider_id, traffic_class, owner)
      when traffic_class in [:live, :vod] and is_pid(owner) do
    safe_call({:acquire, provider_id, traffic_class, owner}, {:ok, :untracked})
  end

  @doc "Releases a previously acquired stream slot."
  @spec release(lease() | :untracked) :: :ok
  def release(:untracked), do: :ok
  def release(lease) when is_reference(lease), do: safe_call({:release, lease}, :ok)

  @doc "Returns the client-safe runtime snapshot for a provider."
  @spec snapshot(integer()) :: map()
  def snapshot(provider_id), do: safe_call({:snapshot, provider_id}, default_snapshot())

  @doc false
  def reset do
    safe_call(:reset, :ok)
  end

  @impl true
  def init(_opts) do
    {:ok, %{providers: %{}, leases: %{}, owners: %{}, monitor_owners: %{}}}
  end

  @impl true
  def handle_call({:put_capabilities, provider_id, capabilities}, _from, state) do
    own_leases = lease_count(state, provider_id)

    state =
      update_provider(state, provider_id, fn provider ->
        %{
          provider
          | capabilities: capabilities,
            external_connections: max(capabilities.active_connections - own_leases, 0)
        }
      end)

    {:reply, :ok, state}
  end

  def handle_call({:record_success, provider_id, dimension, latency_ms}, _from, state) do
    state =
      update_provider(state, provider_id, fn provider ->
        update_in(provider, [:dimensions, dimension], &successful_sample(&1, latency_ms))
      end)

    {:reply, :ok, state}
  end

  def handle_call({:record_failure, provider_id, dimension, reason}, _from, state) do
    state =
      update_provider(state, provider_id, fn provider ->
        update_in(provider, [:dimensions, dimension], &failed_sample(&1, reason))
      end)

    {:reply, :ok, state}
  end

  def handle_call({:acquire, provider_id, traffic_class, owner}, _from, state) do
    provider = Map.get(state.providers, provider_id, new_provider())
    capacity = capacity(provider, lease_count(state, provider_id), traffic_class)

    if capacity.available > 0 do
      lease = make_ref()
      {state, monitor_ref} = ensure_owner_monitor(state, owner)

      lease_data = %{
        provider_id: provider_id,
        traffic_class: traffic_class,
        owner: owner,
        monitor_ref: monitor_ref
      }

      state = %{
        state
        | leases: Map.put(state.leases, lease, lease_data),
          owners: Map.update(state.owners, owner, MapSet.new([lease]), &MapSet.put(&1, lease))
      }

      {:reply, {:ok, lease}, state}
    else
      {:reply, {:error, :capacity_exhausted}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_lease(state, lease)}
  end

  def handle_call({:snapshot, provider_id}, _from, state) do
    provider = Map.get(state.providers, provider_id, new_provider())
    snapshot = provider_snapshot(provider, lease_count(state, provider_id))
    {:reply, snapshot, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.monitor_owners, fn {monitor_ref, _owner} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    {:reply, :ok, %{providers: %{}, leases: %{}, owners: %{}, monitor_owners: %{}}}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    leases = Map.get(state.owners, owner, MapSet.new())

    state =
      Enum.reduce(leases, state, fn lease, acc ->
        %{acc | leases: Map.delete(acc.leases, lease)}
      end)

    {:noreply,
     %{
       state
       | owners: Map.delete(state.owners, owner),
         monitor_owners: Map.delete(state.monitor_owners, monitor_ref)
     }}
  end

  defp update_provider(state, provider_id, fun) do
    %{state | providers: Map.update(state.providers, provider_id, fun.(new_provider()), fun)}
  end

  defp new_provider do
    %{
      capabilities: nil,
      external_connections: 0,
      dimensions: Map.new(@dimensions, &{&1, new_dimension()})
    }
  end

  defp new_dimension do
    %{
      status: :unknown,
      samples: 0,
      successes: 0,
      failures: 0,
      consecutive_failures: 0,
      ewma_latency_ms: nil,
      last_success_at: nil,
      last_error_at: nil,
      last_error: nil
    }
  end

  defp successful_sample(sample, latency_ms) do
    %{
      sample
      | status: :healthy,
        samples: sample.samples + 1,
        successes: sample.successes + 1,
        consecutive_failures: 0,
        ewma_latency_ms: update_ewma(sample.ewma_latency_ms, latency_ms),
        last_success_at: DateTime.utc_now(),
        last_error: nil
    }
  end

  defp failed_sample(sample, reason) do
    consecutive_failures = sample.consecutive_failures + 1

    status =
      cond do
        reason in @terminal_failures -> :unhealthy
        consecutive_failures >= 3 -> :unhealthy
        true -> :degraded
      end

    %{
      sample
      | status: status,
        samples: sample.samples + 1,
        failures: sample.failures + 1,
        consecutive_failures: consecutive_failures,
        last_error_at: DateTime.utc_now(),
        last_error: reason
    }
  end

  defp update_ewma(current, latency_ms) when is_number(latency_ms) and latency_ms >= 0 do
    latency_ms = latency_ms * 1.0

    if is_number(current),
      do: current * (1 - @ewma_alpha) + latency_ms * @ewma_alpha,
      else: latency_ms
  end

  defp update_ewma(current, _), do: current

  defp capacity(provider, leases) do
    capacity(provider, leases, :live)
  end

  defp capacity(provider, leases, traffic_class) do
    capabilities = provider.capabilities
    reported_max_connections = if capabilities, do: capabilities.max_connections, else: 1
    max_connections = connection_ceiling(reported_max_connections, traffic_class)
    observed = if capabilities, do: capabilities.active_connections, else: 0
    external = provider.external_connections
    used = external + leases

    %{
      max_connections: max_connections,
      observed_active_connections: observed,
      external_active_connections: external,
      leased_connections: leases,
      available: max(max_connections - used, 0)
    }
  end

  defp connection_ceiling(_reported_max_connections, :vod) do
    Application.get_env(
      :streamix,
      :vod_connection_ceiling,
      @default_vod_connection_ceiling
    )
  end

  # Xtream accounts routinely under-report `max_connections` — an account that
  # advertises 1 often serves several streams without complaint. Honour the
  # reported value by default (it is the only signal we have), but let an
  # operator who knows better raise it instead of being throttled by a number
  # the provider made up.
  defp connection_ceiling(reported_max_connections, :live) do
    case Application.get_env(:streamix, :live_connection_ceiling) do
      ceiling when is_integer(ceiling) and ceiling > 0 -> ceiling
      _ -> reported_max_connections
    end
  end

  defp provider_snapshot(provider, leases) do
    %{
      capabilities: provider.capabilities && ProviderCapabilities.public(provider.capabilities),
      dimensions: provider.dimensions,
      capacity: capacity(provider, leases)
    }
  end

  defp default_snapshot do
    provider_snapshot(new_provider(), 0)
  end

  defp lease_count(state, provider_id) do
    Enum.count(state.leases, fn {_ref, lease} -> lease.provider_id == provider_id end)
  end

  defp ensure_owner_monitor(state, owner) do
    case Map.get(state.owners, owner) do
      nil ->
        monitor_ref = Process.monitor(owner)

        {%{state | monitor_owners: Map.put(state.monitor_owners, monitor_ref, owner)},
         monitor_ref}

      _leases ->
        {_lease, %{monitor_ref: monitor_ref}} =
          Enum.find(state.leases, fn {_lease, data} -> data.owner == owner end)

        {state, monitor_ref}
    end
  end

  defp release_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {%{owner: owner, monitor_ref: monitor_ref}, leases} ->
        owner_leases = state.owners |> Map.fetch!(owner) |> MapSet.delete(lease)

        if MapSet.size(owner_leases) == 0 do
          Process.demonitor(monitor_ref, [:flush])

          %{
            state
            | leases: leases,
              owners: Map.delete(state.owners, owner),
              monitor_owners: Map.delete(state.monitor_owners, monitor_ref)
          }
        else
          %{state | leases: leases, owners: Map.put(state.owners, owner, owner_leases)}
        end
    end
  end

  # Never keep raw HTTP errors here: they can contain signed URLs or credentials.
  defp sanitize_reason({kind, status})
       when kind in [:unexpected_status, :http_error] and is_integer(status),
       do: %{kind: :http_status, status: status}

  defp sanitize_reason({:transport_error, reason}) when is_atom(reason),
    do: %{kind: :transport, reason: reason}

  defp sanitize_reason({:circuit_open, _seconds}), do: :circuit_open
  defp sanitize_reason(:timeout), do: :timeout
  defp sanitize_reason(:capacity_exhausted), do: :capacity_exhausted
  defp sanitize_reason(reason) when reason in @terminal_failures, do: reason
  defp sanitize_reason(%{__struct__: module}), do: module
  defp sanitize_reason(_), do: :upstream_error

  defp safe_call(message, fallback) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, {:noproc, _} -> fallback
    :exit, {:normal, _} -> fallback
  end
end
