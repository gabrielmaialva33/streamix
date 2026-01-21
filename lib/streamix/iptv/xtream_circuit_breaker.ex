defmodule Streamix.Iptv.XtreamCircuitBreaker do
  @moduledoc """
  Circuit breaker for Xtream IPTV providers.

  Each provider has its own circuit breaker state:
  - CLOSED: Provider is healthy, requests go through
  - OPEN: Provider is unhealthy, requests are blocked (fail fast)
  - HALF_OPEN: Testing if provider recovered

  Netflix-style resilience pattern that:
  - Prevents cascade failures when a provider is down
  - Allows fast failure instead of slow timeouts
  - Auto-recovers after cooldown period
  - Tracks provider health metrics

  Usage:
    # Before making request
    case XtreamCircuitBreaker.allow_request?(provider_id) do
      :ok -> make_request()
      {:error, :circuit_open} -> return cached data or error
    end

    # After request
    XtreamCircuitBreaker.report_success(provider_id)
    XtreamCircuitBreaker.report_error(provider_id)
  """

  use GenServer
  require Logger

  @table_name :xtream_circuit_breakers

  # Circuit breaker settings (Netflix-inspired)
  @error_threshold 5
  @error_window_ms :timer.minutes(1)
  @recovery_timeout :timer.minutes(3)
  @half_open_max_requests 2
  @success_threshold 2

  # Circuit states
  @state_closed :closed
  @state_open :open
  @state_half_open :half_open

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request to the provider is allowed.
  Returns :ok if circuit is closed/half-open, {:error, :circuit_open} otherwise.
  """
  def allow_request?(provider_id) do
    GenServer.call(__MODULE__, {:allow_request, provider_id})
  end

  @doc """
  Reports a successful request to a provider.
  Resets error count and closes circuit if half-open.
  """
  def report_success(provider_id) do
    GenServer.cast(__MODULE__, {:report_success, provider_id})
  end

  @doc """
  Reports a failed request to a provider.
  Increments error count and may open circuit.
  """
  def report_error(provider_id, error_type \\ :unknown) do
    GenServer.cast(__MODULE__, {:report_error, provider_id, error_type})
  end

  @doc """
  Gets the current circuit state for a provider.
  """
  def get_state(provider_id) do
    GenServer.call(__MODULE__, {:get_state, provider_id})
  end

  @doc """
  Gets status of all tracked providers.
  Useful for monitoring dashboards.
  """
  def get_all_status do
    GenServer.call(__MODULE__, :get_all_status)
  end

  @doc """
  Manually resets a provider's circuit breaker.
  """
  def reset(provider_id) do
    GenServer.call(__MODULE__, {:reset, provider_id})
  end

  @doc """
  Manually resets all circuit breakers.
  """
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[XtreamCircuitBreaker] Initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:allow_request, provider_id}, _from, state) do
    circuit = get_or_init_circuit(provider_id)
    now = System.monotonic_time(:millisecond)

    {result, updated_circuit} = check_circuit(circuit, now)

    if updated_circuit != circuit do
      :ets.insert(@table_name, {provider_id, updated_circuit})
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_state, provider_id}, _from, state) do
    circuit = get_or_init_circuit(provider_id)
    {:reply, circuit.circuit_state, state}
  end

  @impl true
  def handle_call(:get_all_status, _from, state) do
    status =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {provider_id, circuit} ->
        %{
          provider_id: provider_id,
          circuit_state: circuit.circuit_state,
          error_count: circuit.error_count,
          success_count: circuit.success_count,
          last_error: circuit.last_error,
          last_error_type: circuit.last_error_type,
          last_success: circuit.last_success,
          opened_at: circuit.opened_at
        }
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_call({:reset, provider_id}, _from, state) do
    circuit = init_circuit()
    :ets.insert(@table_name, {provider_id, circuit})
    Logger.info("[XtreamCircuitBreaker] Circuit reset for provider #{provider_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("[XtreamCircuitBreaker] All circuits reset")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:report_success, provider_id}, state) do
    circuit = get_or_init_circuit(provider_id)
    now = System.monotonic_time(:millisecond)

    new_circuit =
      circuit
      |> Map.put(:last_success, now)
      |> Map.put(:success_count, circuit.success_count + 1)
      |> maybe_close_circuit()

    :ets.insert(@table_name, {provider_id, new_circuit})

    # Log state transitions
    if circuit.circuit_state != @state_closed and new_circuit.circuit_state == @state_closed do
      Logger.info(
        "[XtreamCircuitBreaker] Circuit CLOSED for provider #{provider_id} - recovered after #{new_circuit.success_count} successes"
      )

      emit_telemetry(:circuit_closed, provider_id, new_circuit)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_error, provider_id, error_type}, state) do
    circuit = get_or_init_circuit(provider_id)
    now = System.monotonic_time(:millisecond)

    # Clean old errors outside the window
    recent_errors = clean_old_errors(circuit.error_timestamps, now)
    new_error_count = length(recent_errors) + 1

    new_circuit =
      circuit
      |> Map.put(:error_count, new_error_count)
      |> Map.put(:error_timestamps, [now | recent_errors])
      |> Map.put(:last_error, now)
      |> Map.put(:last_error_type, error_type)
      |> Map.put(:success_count, 0)
      |> maybe_open_circuit(new_error_count, now)

    :ets.insert(@table_name, {provider_id, new_circuit})

    # Log state transitions
    if circuit.circuit_state != @state_open and new_circuit.circuit_state == @state_open do
      Logger.warning(
        "[XtreamCircuitBreaker] Circuit OPEN for provider #{provider_id} after #{new_error_count} errors - " <>
          "blocking requests for #{div(@recovery_timeout, 60_000)} minutes"
      )

      emit_telemetry(:circuit_opened, provider_id, new_circuit)
    end

    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp init_circuit do
    %{
      circuit_state: @state_closed,
      error_count: 0,
      error_timestamps: [],
      success_count: 0,
      half_open_requests: 0,
      last_error: nil,
      last_error_type: nil,
      last_success: nil,
      opened_at: nil
    }
  end

  defp get_or_init_circuit(provider_id) do
    case :ets.lookup(@table_name, provider_id) do
      [{^provider_id, circuit}] -> circuit
      [] -> init_circuit()
    end
  end

  defp check_circuit(circuit, now) do
    case circuit.circuit_state do
      @state_closed ->
        {:ok, circuit}

      @state_open ->
        time_since_open = now - (circuit.opened_at || now)

        if time_since_open >= @recovery_timeout do
          Logger.info("[XtreamCircuitBreaker] Circuit transitioning to HALF-OPEN for testing")

          new_circuit = %{
            circuit
            | circuit_state: @state_half_open,
              half_open_requests: 1,
              success_count: 0
          }

          {:ok, new_circuit}
        else
          remaining = div(@recovery_timeout - time_since_open, 1000)
          {{:error, {:circuit_open, remaining}}, circuit}
        end

      @state_half_open ->
        if circuit.half_open_requests < @half_open_max_requests do
          new_circuit = %{circuit | half_open_requests: circuit.half_open_requests + 1}
          {:ok, new_circuit}
        else
          {{:error, :circuit_half_open_limit}, circuit}
        end
    end
  end

  defp maybe_open_circuit(circuit, error_count, now) do
    cond do
      circuit.circuit_state == @state_half_open ->
        # Failed during half-open test - back to open
        %{
          circuit
          | circuit_state: @state_open,
            opened_at: now,
            half_open_requests: 0
        }

      error_count >= @error_threshold ->
        %{circuit | circuit_state: @state_open, opened_at: now}

      true ->
        circuit
    end
  end

  defp maybe_close_circuit(circuit) do
    case circuit.circuit_state do
      @state_half_open ->
        if circuit.success_count >= @success_threshold do
          %{
            circuit
            | circuit_state: @state_closed,
              half_open_requests: 0,
              opened_at: nil,
              error_count: 0,
              error_timestamps: []
          }
        else
          circuit
        end

      @state_closed ->
        # Reset error count on success in closed state
        %{circuit | error_count: 0, error_timestamps: []}

      _ ->
        circuit
    end
  end

  defp clean_old_errors(timestamps, now) do
    Enum.filter(timestamps, fn ts -> now - ts < @error_window_ms end)
  end

  defp emit_telemetry(event, provider_id, circuit) do
    :telemetry.execute(
      [:streamix, :iptv, :circuit_breaker, event],
      %{timestamp: System.system_time(:millisecond)},
      %{
        provider_id: provider_id,
        error_count: circuit.error_count,
        circuit_state: circuit.circuit_state
      }
    )
  end
end
