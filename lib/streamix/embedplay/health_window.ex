defmodule Streamix.Embedplay.HealthWindow do
  @moduledoc """
  Bounded sliding window of Embedplay resolution outcomes, and the rule that
  decides when they add up to a systemic failure.

  Pure data: `Streamix.Embedplay.Health` owns the process and the side
  effects. Time is passed in (monotonic milliseconds) so the rule can be
  exercised without waiting.

  ## Classification

    * `{:error, :resolver_outdated}` — the resolver no longer recognises the
      upstream page. That is a statement about the site, not about a title, so
      it trips after `:outdated_trip_movies` distinct titles report it.
    * `{:error, :no_source_available}` — may be a single title without a
      source. It only trips as a rate: at least `:trip_failures` failures over
      at least `:trip_movies` *distinct* titles with no success in between.
      Distinct titles matter because many viewers retrying one dead title is
      not evidence about the others.
    * `:upstream_timeout`, `:provider_capacity_exhausted`,
      `:stream_resolution_failed` and any unknown error are transient: they
      are recorded for visibility but never trip on their own and do not
      reset the streak either.
    * `:provider_disabled` and `:provider_degraded` describe our own state,
      not the upstream's, and are ignored.

  Any success resets the failure streak. A success that reuses a session
  already counted (a cached resolution handed to another viewer) is ignored:
  it is not fresh evidence that resolution works today.
  """

  @enforce_keys [:entries, :tripped?]
  defstruct entries: [], tripped?: false

  @ignored ~w(provider_disabled provider_degraded)a

  @type outcome :: :success | :failure | :transient
  @type entry :: %{
          outcome: outcome(),
          reason: atom() | nil,
          movie_id: term(),
          session_id: term(),
          at: integer()
        }
  @type t :: %__MODULE__{entries: [entry()], tripped?: boolean()}
  @type thresholds :: %{
          window_ms: pos_integer(),
          max_entries: pos_integer(),
          trip_failures: pos_integer(),
          trip_movies: pos_integer(),
          outdated_trip_movies: pos_integer()
        }
  @type streak :: %{
          failures: non_neg_integer(),
          movies: non_neg_integer(),
          reasons: %{optional(atom()) => pos_integer()},
          window_seconds: non_neg_integer()
        }
  @type decision :: :ignored | :recorded | {:trip, atom(), streak()} | {:recover, streak()}

  @spec new() :: t()
  def new, do: %__MODULE__{entries: [], tripped?: false}

  @doc "Maps a resolution result to the outcome the window understands."
  @spec classify(term()) ::
          {:success, term()} | {:failure, atom()} | {:transient, atom()} | :ignore
  def classify({:ok, source}) when is_map(source), do: {:success, Map.get(source, :session_id)}
  def classify({:error, :resolver_outdated}), do: {:failure, :resolver_outdated}
  def classify({:error, :no_source_available}), do: {:failure, :no_source_available}
  def classify({:error, reason}) when reason in @ignored, do: :ignore
  # `:upstream_timeout`, `:provider_capacity_exhausted`, `:stream_resolution_failed`
  # and anything new the resolver starts reporting.
  def classify({:error, reason}) when is_atom(reason), do: {:transient, reason}
  def classify(_result), do: {:transient, :stream_resolution_failed}

  @doc """
  Records one resolution result for `movie_id` at monotonic time `now`.

  Returns `{:trip, reason, streak}` every time a failure leaves the trip
  condition satisfied — the caller persists idempotently, so repeating it is
  harmless — and `{:recover, streak}` for the first success after a trip.
  """
  @spec record(t(), term(), term(), integer(), thresholds()) :: {decision(), t()}
  def record(%__MODULE__{} = window, movie_id, result, now, thresholds) do
    window = prune(window, now, thresholds)

    case classify(result) do
      :ignore ->
        {:ignored, window}

      {:success, session_id} ->
        record_success(window, movie_id, session_id, now, thresholds)

      {outcome, reason} ->
        entry = %{outcome: outcome, reason: reason, movie_id: movie_id, session_id: nil, at: now}
        window = push(window, entry, thresholds)
        evaluate(window, thresholds)
    end
  end

  @doc """
  Point-in-time view of the window for logs and `Streamix.Embedplay.health/0`.
  """
  @spec summary(t(), integer(), thresholds()) :: map()
  def summary(%__MODULE__{} = window, now, thresholds) do
    window = prune(window, now, thresholds)
    counts = Enum.frequencies_by(window.entries, & &1.outcome)

    %{
      window_seconds: div(thresholds.window_ms, 1000),
      successes: Map.get(counts, :success, 0),
      failures: Map.get(counts, :failure, 0),
      transient: Map.get(counts, :transient, 0),
      streak: streak(window, thresholds),
      seconds_since_last_outcome: seconds_since(List.first(window.entries), now),
      seconds_since_last_success:
        seconds_since(Enum.find(window.entries, &(&1.outcome == :success)), now)
    }
  end

  @doc "Movies that failed since the last success, newest first."
  @spec streak_movie_ids(t()) :: [term()]
  def streak_movie_ids(%__MODULE__{} = window) do
    window
    |> streak_failures()
    |> Enum.map(& &1.movie_id)
    |> Enum.uniq()
  end

  defp record_success(window, movie_id, session_id, now, thresholds) do
    if session_id != nil and Enum.any?(window.entries, &(&1.session_id == session_id)) do
      {:ignored, window}
    else
      entry = %{
        outcome: :success,
        reason: nil,
        movie_id: movie_id,
        session_id: session_id,
        at: now
      }

      window = push(window, entry, thresholds)

      if window.tripped? do
        {{:recover, streak(window, thresholds)}, %{window | tripped?: false}}
      else
        {:recorded, window}
      end
    end
  end

  defp evaluate(window, thresholds) do
    failures = streak_failures(window)
    movies = distinct_movies(failures)

    outdated_movies =
      failures |> Enum.filter(&(&1.reason == :resolver_outdated)) |> distinct_movies()

    reason =
      cond do
        outdated_movies >= thresholds.outdated_trip_movies ->
          :resolver_outdated

        length(failures) >= thresholds.trip_failures and movies >= thresholds.trip_movies ->
          dominant_reason(failures)

        true ->
          nil
      end

    if reason do
      {{:trip, reason, streak(window, thresholds)}, %{window | tripped?: true}}
    else
      {:recorded, window}
    end
  end

  defp streak(window, thresholds) do
    failures = streak_failures(window)

    %{
      failures: length(failures),
      movies: distinct_movies(failures),
      reasons: Enum.frequencies_by(failures, & &1.reason),
      window_seconds: div(thresholds.window_ms, 1000)
    }
  end

  # Entries are newest first, so the streak is everything before the most
  # recent success.
  defp streak_failures(window) do
    window.entries
    |> Enum.take_while(&(&1.outcome != :success))
    |> Enum.filter(&(&1.outcome == :failure))
  end

  defp distinct_movies(entries) do
    entries |> Enum.map(& &1.movie_id) |> Enum.uniq() |> length()
  end

  # Ties go to `:resolver_outdated`, the more specific diagnosis.
  defp dominant_reason(failures) do
    failures
    |> Enum.frequencies_by(& &1.reason)
    |> Enum.max_by(fn {reason, count} -> {count, reason == :resolver_outdated} end)
    |> elem(0)
  end

  defp push(window, entry, thresholds) do
    %{window | entries: Enum.take([entry | window.entries], thresholds.max_entries)}
  end

  defp prune(window, now, thresholds) do
    cutoff = now - thresholds.window_ms
    %{window | entries: Enum.take_while(window.entries, &(&1.at > cutoff))}
  end

  defp seconds_since(nil, _now), do: nil
  defp seconds_since(%{at: at}, now), do: div(max(now - at, 0), 1000)
end
