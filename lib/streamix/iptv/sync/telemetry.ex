defmodule Streamix.Iptv.Sync.Telemetry do
  @moduledoc """
  Telemetry events for IPTV sync operations.

  ## Events

  ### `[:streamix, :sync, :start]`
  Emitted when a full sync starts for a provider.

  Measurements: `%{system_time: integer}`
  Metadata: `%{provider_id: integer, provider_name: string}`

  ### `[:streamix, :sync, :stop]`
  Emitted when a full sync completes (success or failure).

  Measurements: `%{duration: integer}` (native time units)
  Metadata: `%{provider_id: integer, status: :ok | :error | :partial, counts: map}`

  ### `[:streamix, :sync, :progress]`
  Emitted during sync to report progress.

  Measurements: `%{percent: integer, current: integer, total: integer}`
  Metadata: `%{provider_id: integer, phase: atom, type: atom}`

  ### `[:streamix, :sync, :batch]`
  Emitted when a batch of content is synced.

  Measurements: `%{count: integer, duration: integer}`
  Metadata: `%{provider_id: integer, type: atom, batch_number: integer}`

  ### `[:streamix, :sync, :api_call]`
  Emitted for each Xtream API call.

  Measurements: `%{duration: integer}`
  Metadata: `%{provider_id: integer, action: string, status: :ok | :error}`

  ## Usage

      # In your code:
      Streamix.Iptv.Sync.Telemetry.sync_start(provider)

      # ... do sync ...

      Streamix.Iptv.Sync.Telemetry.sync_stop(provider, start_time, :ok, counts)

  ## Attaching Handlers

      :telemetry.attach_many(
        "sync-logger",
        [
          [:streamix, :sync, :start],
          [:streamix, :sync, :stop],
          [:streamix, :sync, :progress]
        ],
        &MyApp.SyncLogger.handle_event/4,
        nil
      )

  """

  @prefix [:streamix, :sync]

  # ===========================================================================
  # Sync Lifecycle
  # ===========================================================================

  @doc """
  Emits sync start event. Returns monotonic start time for duration calculation.
  """
  def sync_start(provider) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      @prefix ++ [:start],
      %{system_time: System.system_time()},
      %{
        provider_id: provider.id,
        provider_name: provider.name || "unknown"
      }
    )

    start_time
  end

  @doc """
  Emits sync stop event with duration and results.
  """
  def sync_stop(provider, start_time, status, counts \\ %{}) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @prefix ++ [:stop],
      %{duration: duration},
      %{
        provider_id: provider.id,
        status: status,
        counts: counts
      }
    )
  end

  # ===========================================================================
  # Progress Tracking
  # ===========================================================================

  @doc """
  Emits progress event. Use for long-running operations.

  ## Phases
    - :categories - Syncing categories
    - :content - Syncing live/movies/series
    - :details - Syncing series details
    - :cleanup - Cleaning up orphaned data

  ## Types (for :content phase)
    - :live, :movies, :series
  """
  def progress(provider, phase, opts \\ []) do
    current = Keyword.get(opts, :current, 0)
    total = Keyword.get(opts, :total, 0)
    type = Keyword.get(opts, :type)

    percent =
      if total > 0 do
        round(current / total * 100)
      else
        0
      end

    :telemetry.execute(
      @prefix ++ [:progress],
      %{percent: percent, current: current, total: total},
      %{
        provider_id: provider.id,
        phase: phase,
        type: type
      }
    )

    # Also broadcast via PubSub for LiveView updates
    broadcast_progress(provider, phase, percent, type)
  end

  # ===========================================================================
  # Batch Operations
  # ===========================================================================

  @doc """
  Emits batch completion event.
  """
  def batch_complete(provider, type, batch_number, count, duration) do
    :telemetry.execute(
      @prefix ++ [:batch],
      %{count: count, duration: duration},
      %{
        provider_id: provider.id,
        type: type,
        batch_number: batch_number
      }
    )
  end

  @doc """
  Wraps a batch operation with timing telemetry.
  """
  def span_batch(provider, type, batch_number, fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    count =
      case result do
        {n, _} when is_integer(n) -> n
        n when is_integer(n) -> n
        _ -> 0
      end

    batch_complete(provider, type, batch_number, count, duration)
    result
  end

  # ===========================================================================
  # API Calls
  # ===========================================================================

  @doc """
  Wraps an API call with timing telemetry.
  """
  def span_api_call(provider_id, action, fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start

    status = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      @prefix ++ [:api_call],
      %{duration: duration},
      %{
        provider_id: provider_id,
        action: action,
        status: status
      }
    )

    result
  end

  # ===========================================================================
  # PubSub Broadcasting
  # ===========================================================================

  defp broadcast_progress(provider, phase, percent, type) do
    message = %{
      event: :sync_progress,
      provider_id: provider.id,
      phase: phase,
      percent: percent,
      type: type
    }

    # Broadcast to provider-specific topic
    Phoenix.PubSub.broadcast(
      Streamix.PubSub,
      "provider:#{provider.id}",
      {:sync_progress, message}
    )

    # Broadcast to user's providers list
    if provider.user_id do
      Phoenix.PubSub.broadcast(
        Streamix.PubSub,
        "user:#{provider.user_id}:providers",
        {:sync_progress, message}
      )
    end
  end
end
