defmodule Streamix.Iptv.Gindex.EndpointManager do
  @moduledoc """
  Manages multiple GIndex endpoints with health-based circuit breakers.

  Each endpoint has its own circuit breaker state:
  - CLOSED: Endpoint is healthy, requests go through
  - OPEN: Endpoint is unhealthy, requests are blocked
  - HALF_OPEN: Testing if endpoint recovered

  The manager automatically:
  - Routes requests to healthy endpoints
  - Falls back to secondary endpoints when primary fails
  - Recovers endpoints after cooldown period
  """

  use GenServer
  require Logger

  @table_name :gindex_endpoints
  # Three mirrors confirmed live as of 2026-04-20 via enum + 20-burst
  # each = 60/60 200. All three expose the identical 5-drive catalog
  # (Animes / Desenhos / Filmes / Novelas / Outros), so EndpointManager
  # can swap between them transparently. Keeping them as distinct hosts
  # matters for the rate-limit story: the upstream Cloudflare Worker
  # seems to throttle per-hostname, so spreading concurrent scanners
  # across the pool buys roughly triple the effective request budget.
  # Priority 1 is the only mirror serving paginated listings reliably.
  # The other two return HTTP 500 on every page beyond index 0
  # (`TypeError: Cannot read properties of undefined (reading 'map')`),
  # which is a bug in their deployed worker.js — the `data.files`
  # array is null when the upstream Drive folder is too big to fit
  # in a single response. Promote the healthy mirror; HealthTracker
  # will recycle the others if/when their owners ship a fix.
  @default_endpoints [
    %{
      name: :primary,
      url: "https://1.animezey23112022.workers.dev",
      priority: 1
    },
    %{
      name: :mirror_animezey16082023,
      url: "https://animezey16082023.animezey16082023.workers.dev",
      priority: 2
    },
    %{
      name: :mirror_animezeydl,
      url: "https://1.animezeydl.workers.dev",
      priority: 3
    }
  ]

  # Circuit breaker settings
  # 5xx bursts from the upstream Cloudflare Worker are routinely
  # transient (the worker itself logs `TypeError` on some shards), so
  # `@error_threshold` sits well above the natural burst size and
  # `@recovery_timeout` is short enough that a healthy primary is back
  # in rotation before the user-visible sync window closes.
  @error_threshold 10
  @recovery_timeout :timer.minutes(1)
  @half_open_max_requests 2

  # Circuit states
  @state_closed :closed
  @state_open :open
  @state_half_open :half_open

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the best available endpoint URL.
  Returns the highest priority endpoint with a closed or half-open circuit.
  """
  def get_endpoint do
    GenServer.call(__MODULE__, :get_endpoint)
  end

  @doc """
  Gets a specific endpoint by name.
  """
  def get_endpoint(name) when is_atom(name) or is_binary(name) do
    GenServer.call(__MODULE__, {:get_endpoint, name})
  end

  @doc """
  Reports a successful request to an endpoint.
  Resets error count and closes circuit if half-open.
  """
  def report_success(url) do
    GenServer.cast(__MODULE__, {:report_success, url})
  end

  @doc """
  Reports a failed request to an endpoint.
  Increments error count and may open circuit.
  """
  def report_error(url) do
    GenServer.cast(__MODULE__, {:report_error, url})
  end

  @doc """
  Gets the current status of all endpoints.
  Useful for monitoring and debugging.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Manually resets all circuit breakers.
  """
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @doc """
  Gets all configured endpoint URLs for iteration (e.g., syncing from all sources).
  Returns list of {name, url} tuples ordered by priority.
  """
  def get_all_endpoints do
    GenServer.call(__MODULE__, :get_all_endpoints)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @table_name)

    # Create ETS table for fast reads
    :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])

    # Initialize endpoints from config or defaults
    endpoints = get_configured_endpoints(opts)

    for endpoint <- endpoints do
      init_endpoint(endpoint, table_name)
    end

    Logger.info("[GIndex EndpointManager] Initialized with #{length(endpoints)} endpoints")

    {:ok, %{endpoints: endpoints, table_name: table_name}}
  end

  @impl true
  def handle_call(:get_endpoint, _from, state) do
    endpoint = find_best_endpoint(state.table_name)
    {:reply, endpoint, state}
  end

  @impl true
  def handle_call({:get_endpoint, name}, _from, state) do
    case :ets.lookup(state.table_name, name) do
      [{^name, endpoint_state}] -> {:reply, {:ok, endpoint_state.url}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status =
      :ets.tab2list(state.table_name)
      |> Enum.map(fn {name, endpoint_state} ->
        %{
          name: name,
          url: endpoint_state.url,
          priority: endpoint_state.priority,
          circuit_state: endpoint_state.circuit_state,
          error_count: endpoint_state.error_count,
          last_error: endpoint_state.last_error,
          last_success: endpoint_state.last_success
        }
      end)
      |> Enum.sort_by(& &1.priority)

    {:reply, status, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    for {name, endpoint_state} <- :ets.tab2list(state.table_name) do
      :ets.insert(state.table_name, {name, reset_endpoint_state(endpoint_state)})
    end

    Logger.info("[GIndex EndpointManager] All circuit breakers reset")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_endpoints, _from, state) do
    endpoints =
      :ets.tab2list(state.table_name)
      |> Enum.map(fn {name, endpoint_state} ->
        %{name: name, url: endpoint_state.url, priority: endpoint_state.priority}
      end)
      |> Enum.sort_by(& &1.priority)

    {:reply, {:ok, endpoints}, state}
  end

  @impl true
  def handle_cast({:report_success, url}, state) do
    case find_endpoint_by_url(state.table_name, url) do
      {name, endpoint_state} ->
        new_state =
          endpoint_state
          |> Map.put(:error_count, 0)
          |> Map.put(:last_success, System.monotonic_time(:millisecond))
          |> maybe_close_circuit()

        :ets.insert(state.table_name, {name, new_state})

        if endpoint_state.circuit_state != @state_closed and
             new_state.circuit_state == @state_closed do
          Logger.info("[GIndex EndpointManager] Circuit CLOSED for #{name} - endpoint recovered")
        end

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_error, url}, state) do
    case find_endpoint_by_url(state.table_name, url) do
      {name, endpoint_state} ->
        new_error_count = endpoint_state.error_count + 1
        now = System.monotonic_time(:millisecond)

        new_state =
          endpoint_state
          |> Map.put(:error_count, new_error_count)
          |> Map.put(:last_error, now)
          |> maybe_open_circuit(new_error_count, now)

        :ets.insert(state.table_name, {name, new_state})

        if endpoint_state.circuit_state != @state_open and new_state.circuit_state == @state_open do
          Logger.warning(
            "[GIndex EndpointManager] Circuit OPEN for #{name} after #{new_error_count} errors - " <>
              "switching to fallback for #{div(@recovery_timeout, 60_000)} minutes"
          )
        end

      nil ->
        :ok
    end

    {:noreply, state}
  end

  # Private functions

  defp get_configured_endpoints(opts) do
    case Keyword.get(opts, :endpoints) do
      [_ | _] = endpoints when is_binary(hd(endpoints)) ->
        build_endpoints_from_list(endpoints)

      [_ | _] = endpoints ->
        endpoints

      _ ->
        @default_endpoints
    end
    |> case do
      @default_endpoints = default_endpoints ->
        case Application.get_env(:streamix, :gindex_provider) do
          config when is_list(config) -> parse_gindex_config(config)
          _ -> default_endpoints
        end

      endpoints ->
        endpoints
    end
  end

  defp parse_gindex_config(config) do
    case Keyword.get(config, :endpoints) do
      [_ | _] = endpoints -> build_endpoints_from_list(endpoints)
      _ -> parse_single_url_config(config)
    end
  end

  defp build_endpoints_from_list(endpoints) do
    endpoints
    |> Enum.with_index(1)
    |> Enum.map(fn {url, priority} ->
      name = "endpoint_#{priority}"
      %{name: name, url: url, priority: priority}
    end)
  end

  defp parse_single_url_config(config) do
    case Keyword.get(config, :url) do
      url when is_binary(url) ->
        # Respect the operator's chosen primary, but still benefit from
        # the live-mirror pool in `@default_endpoints`. Deduplicate on
        # host+path so we don't register the same Worker twice when the
        # env URL happens to match one of the defaults.
        primary = %{name: :primary, url: url, priority: 1}

        fallbacks =
          @default_endpoints
          |> Enum.reject(&same_host?(&1.url, url))
          |> Enum.with_index(2)
          |> Enum.map(fn {ep, priority} ->
            %{ep | name: fallback_name(ep.name, priority), priority: priority}
          end)

        [primary | fallbacks]

      _ ->
        @default_endpoints
    end
  end

  defp fallback_name(:primary, priority), do: "fallback_#{priority}"
  defp fallback_name(name, _priority), do: name

  defp same_host?(url_a, url_b) do
    normalize(url_a) == normalize(url_b)
  end

  defp normalize(url) do
    url
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp init_endpoint(endpoint, table_name) do
    state = %{
      url: endpoint.url,
      priority: endpoint.priority,
      circuit_state: @state_closed,
      error_count: 0,
      half_open_requests: 0,
      last_error: nil,
      last_success: nil,
      opened_at: nil
    }

    :ets.insert(table_name, {endpoint.name, state})
  end

  defp reset_endpoint_state(endpoint_state) do
    %{
      endpoint_state
      | circuit_state: @state_closed,
        error_count: 0,
        half_open_requests: 0,
        last_error: nil,
        opened_at: nil
    }
  end

  defp find_best_endpoint(table_name) do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(table_name)
    |> Enum.map(fn {name, state} -> {name, maybe_transition_to_half_open(state, now)} end)
    |> Enum.filter(fn {_name, state} ->
      state.circuit_state in [@state_closed, @state_half_open]
    end)
    |> Enum.sort_by(fn {_name, state} -> state.priority end)
    |> select_endpoint(table_name)
  end

  defp select_endpoint([{name, state} | _], table_name) do
    # Update state if transitioned to half-open
    if state.circuit_state == @state_half_open do
      new_state = %{state | half_open_requests: state.half_open_requests + 1}
      :ets.insert(table_name, {name, new_state})
    end

    {:ok, state.url}
  end

  defp select_endpoint([], table_name) do
    # All circuits open - return primary anyway (will likely fail but allows retry)
    Logger.warning("[GIndex EndpointManager] All circuits OPEN - forcing primary endpoint")
    get_fallback_endpoint(table_name)
  end

  defp get_fallback_endpoint(table_name) do
    case :ets.lookup(table_name, :primary) do
      [{:primary, state}] -> {:ok, state.url}
      [] -> get_first_available_endpoint(table_name)
    end
  end

  defp get_first_available_endpoint(table_name) do
    case :ets.first(table_name) do
      :"$end_of_table" ->
        {:error, :no_endpoints}

      name ->
        [{^name, state}] = :ets.lookup(table_name, name)
        {:ok, state.url}
    end
  end

  defp find_endpoint_by_url(table_name, url) do
    :ets.tab2list(table_name)
    |> Enum.find(fn {_name, state} -> state.url == url end)
  end

  defp maybe_transition_to_half_open(state, now) do
    if state.circuit_state == @state_open do
      time_since_open = now - (state.opened_at || now)

      if time_since_open >= @recovery_timeout do
        Logger.info("[GIndex EndpointManager] Circuit transitioning to HALF-OPEN for testing")
        %{state | circuit_state: @state_half_open, half_open_requests: 0}
      else
        state
      end
    else
      state
    end
  end

  defp maybe_open_circuit(state, error_count, now) do
    cond do
      state.circuit_state == @state_half_open ->
        # Failed during half-open test - back to open
        %{state | circuit_state: @state_open, opened_at: now, half_open_requests: 0}

      error_count >= @error_threshold ->
        %{state | circuit_state: @state_open, opened_at: now}

      true ->
        state
    end
  end

  defp maybe_close_circuit(state) do
    case state.circuit_state do
      @state_half_open ->
        if state.half_open_requests >= @half_open_max_requests do
          %{state | circuit_state: @state_closed, half_open_requests: 0, opened_at: nil}
        else
          state
        end

      _ ->
        state
    end
  end
end
