defmodule Streamix.Embedplay.Health do
  @moduledoc """
  Detects systematic Embedplay resolution failure and keeps the provider's
  persisted health state in step with it.

  Every playback open is observed (`guard/2`). When the outcomes add up to a
  systemic failure (`Streamix.Embedplay.HealthWindow` holds the rule), the
  system provider is marked degraded: its catalog drops out of every browse
  query (`Streamix.Iptv.Access.browsable/2`) and new opens fail at once with
  `{:error, :provider_degraded}` instead of spending seconds on a browser
  resolution that cannot succeed. A successful resolution — normally the
  canary, `Streamix.Embedplay.Canary` — clears it.

  The degraded state lives in `providers.health_status`, never in
  `is_active`: that column is the operator's switch, and automatic recovery
  must not re-enable a provider someone turned off on purpose.

  ## Why a GenServer, and why its state may be lost

  Outcomes arrive from many request processes at once, and a trip decision is
  a read-modify-write over the whole window, so the window is serialized
  through one process. It is in memory only. Losing it on deploy is
  acceptable: the persisted `health_status` keeps a broken catalog hidden
  across restarts, and an empty window reads as idle, so the first canary tick
  after boot probes and re-establishes the truth. ETS would not remove the
  need for serialization, and the volume — one call per playback start — is
  far below what a single process handles.

  The process does no I/O. Persisting a transition happens in the calling
  process with conditional updates, so concurrent callers agree on a single
  transition (only one of them logs it), playback never queues behind a
  database write, and a call that cannot reach this process degrades to "not
  observed" rather than failing the playback.
  """

  use GenServer

  require Logger

  alias Streamix.{Cache, Embedplay, Providers}
  alias Streamix.Embedplay.HealthWindow

  # Defaults also listed, with their rationale, in config/config.exs.
  @window_seconds 21_600
  @window_size 200
  @trip_failures 5
  @trip_movies 5
  @outdated_trip_movies 2
  @call_timeout 1_000

  # -- Client ------------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs `open` (a playback open for `movie`) unless the provider is degraded,
  and records its outcome.
  """
  @spec guard(map(), (-> term()), keyword()) :: term()
  def guard(movie, open, opts \\ []) when is_function(open, 0) do
    if degraded?(movie) do
      {:error, :provider_degraded}
    else
      result = open.()
      observe(movie.id, result, opts)
      result
    end
  end

  @doc """
  Records one resolution `result` for `movie_id` and applies any resulting
  transition.

  ## Options

    * `:server` — the window process (default `#{inspect(__MODULE__)}`)
    * `:source` — who produced the result, for logs (default `:playback`)
    * `:recover` — when `true`, a success clears a degraded state even if this
      process never saw the trip (the canary passes it: the window may have
      been lost on deploy while the persisted state survived)
  """
  # Known, bounded race: the window decides transitions in one process, but
  # the persisted write happens in the caller. A trip decided just before a
  # recovery can therefore be *written* after it, leaving the row degraded
  # while the window believes it is healthy. It is left in place rather than
  # moving database I/O into the window process: the canary probes on every
  # tick while the row says degraded and passes `recover: true`, so the state
  # converges within one tick (30 minutes) without anyone acting on it.
  @spec observe(term(), term(), keyword()) :: :ok
  def observe(movie_id, result, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    source = Keyword.get(opts, :source, :playback)

    case {call(server, {:record, movie_id, result}, :ignored), result} do
      {{:trip, reason, streak}, _result} -> degrade(reason, streak, source)
      {{:recover, _streak}, _result} -> recover(source)
      {_decision, {:ok, _source}} -> if Keyword.get(opts, :recover, false), do: recover(source)
      _other -> :ok
    end

    :ok
  end

  @doc "Whether new playback through `movie`'s provider must fail fast."
  @spec degraded?(map()) :: boolean()
  def degraded?(%{provider: %{health_status: status}}), do: status == :degraded

  def degraded?(_movie),
    do: match?(%{health_status: :degraded}, Providers.get_embedplay_provider())

  @doc "Persisted health state plus a summary of the observation window."
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    provider = if Embedplay.enabled?(), do: Providers.get_embedplay_provider()

    provider
    |> persisted_status()
    |> Map.put(:window, summary(opts))
  end

  @doc "Summary of the observation window, or `nil` when it is unreachable."
  @spec summary(keyword()) :: map() | nil
  def summary(opts \\ []), do: call(Keyword.get(opts, :server, __MODULE__), :summary, nil)

  @doc "Movies that failed since the last success; a probe should try others."
  @spec failing_movie_ids(keyword()) :: [term()]
  def failing_movie_ids(opts \\ []),
    do: call(Keyword.get(opts, :server, __MODULE__), :failing_movie_ids, [])

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, HealthWindow.new()}

  @impl true
  def handle_call({:record, movie_id, result}, _from, window) do
    {decision, window} = HealthWindow.record(window, movie_id, result, now(), thresholds())
    {:reply, decision, window}
  end

  def handle_call(:summary, _from, window),
    do: {:reply, HealthWindow.summary(window, now(), thresholds()), window}

  def handle_call(:failing_movie_ids, _from, window),
    do: {:reply, HealthWindow.streak_movie_ids(window), window}

  # -- Transitions -------------------------------------------------------------

  defp degrade(reason, streak, source) do
    case Providers.mark_embedplay_degraded(reason) do
      {:ok, _provider} ->
        Logger.warning(
          "[Embedplay] resolution degraded: reason=#{reason} " <>
            "failures=#{streak.failures} distinct_movies=#{streak.movies} " <>
            "reasons=#{inspect(streak.reasons)} window=#{streak.window_seconds}s " <>
            "source=#{source}; catalog hidden and playback failing fast until a probe resolves"
        )

        invalidate_catalog()

      :unchanged ->
        :ok
    end
  rescue
    exception -> log_transition_error(:degrade, exception)
  end

  defp recover(source) do
    case Providers.mark_embedplay_healthy() do
      {:ok, previous} ->
        Logger.info(
          "[Embedplay] resolution recovered: previous_reason=#{previous.degraded_reason} " <>
            "degraded_for=#{degraded_for(previous.degraded_at)}s source=#{source}; " <>
            "catalog visible again"
        )

        invalidate_catalog()

      :unchanged ->
        :ok
    end
  rescue
    exception -> log_transition_error(:recover, exception)
  end

  # Shelves are cached for up to a day; without this the change would only
  # show up as each entry expires.
  defp invalidate_catalog do
    Cache.invalidate_public_catalog()
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_transition_error(transition, exception) do
    Logger.error(
      "[Embedplay] health #{transition} could not be persisted: " <>
        Exception.message(exception)
    )
  end

  defp degraded_for(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at)
  defp degraded_for(_at), do: 0

  defp persisted_status(nil),
    do: %{status: :disabled, active: false, reason: nil, degraded_at: nil}

  defp persisted_status(provider) do
    %{
      status: provider.health_status,
      active: provider.is_active,
      reason: provider.degraded_reason,
      degraded_at: provider.degraded_at
    }
  end

  defp call(server, message, fallback) do
    GenServer.call(server, message, @call_timeout)
  catch
    :exit, _reason -> fallback
  end

  defp thresholds do
    %{
      window_ms: Embedplay.config(:health_window_seconds, @window_seconds) * 1000,
      max_entries: Embedplay.config(:health_window_size, @window_size),
      trip_failures: Embedplay.config(:health_trip_failures, @trip_failures),
      trip_movies: Embedplay.config(:health_trip_movies, @trip_movies),
      outdated_trip_movies: Embedplay.config(:health_outdated_trip_movies, @outdated_trip_movies)
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
