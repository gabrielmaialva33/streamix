defmodule Streamix.Embedplay.HealthWindowTest do
  use ExUnit.Case, async: true

  alias Streamix.Embedplay.HealthWindow

  @thresholds %{
    window_ms: 21_600_000,
    max_entries: 200,
    trip_failures: 5,
    trip_movies: 5,
    outdated_trip_movies: 2
  }

  @no_source {:error, :no_source_available}
  @outdated {:error, :resolver_outdated}

  defp success(session_id \\ nil), do: {:ok, %{session_id: session_id, resource_id: "r"}}

  # Feeds `{movie_id, result}` pairs one millisecond apart and returns every
  # decision alongside the final window.
  defp feed(window \\ HealthWindow.new(), events, start \\ 0, thresholds \\ @thresholds) do
    {decisions, {window, _now}} =
      Enum.map_reduce(events, {window, start}, fn {movie_id, result}, {window, now} ->
        {decision, window} = HealthWindow.record(window, movie_id, result, now, thresholds)
        {decision, {window, now + 1}}
      end)

    {decisions, window}
  end

  describe "no_source_available" do
    test "trips on the fifth failure across five distinct movies" do
      {decisions, _window} = feed(for id <- 1..5, do: {id, @no_source})

      assert Enum.take(decisions, 4) == List.duplicate(:recorded, 4)

      assert {:trip, :no_source_available, %{failures: 5, movies: 5}} = List.last(decisions)
    end

    test "many failures of the same few titles never trip" do
      events = for _round <- 1..10, id <- 1..4, do: {id, @no_source}
      {decisions, window} = feed(events)

      assert Enum.all?(decisions, &(&1 == :recorded))

      assert %{streak: %{failures: 40, movies: 4}} =
               HealthWindow.summary(window, 100, @thresholds)
    end

    test "a success anywhere in the run resets the streak" do
      events =
        for(id <- 1..4, do: {id, @no_source}) ++
          [{99, success()}] ++ for id <- 5..8, do: {id, @no_source}

      {decisions, window} = feed(events)

      assert Enum.all?(decisions, &(&1 == :recorded))
      assert %{streak: %{failures: 4, movies: 4}} = HealthWindow.summary(window, 9, @thresholds)

      {decisions, _window} = feed(window, [{9, @no_source}], 9)
      assert [{:trip, :no_source_available, %{failures: 5, movies: 5}}] = decisions
    end

    test "both the failure count and the distinct-movie count are honoured" do
      thresholds = %{@thresholds | trip_failures: 8, trip_movies: 3}
      events = for id <- [1, 2, 3, 1, 2, 3, 1], do: {id, @no_source}

      {decisions, window} = feed(HealthWindow.new(), events, 0, thresholds)
      assert Enum.all?(decisions, &(&1 == :recorded))

      {decisions, _window} = feed(window, [{2, @no_source}], 7, thresholds)
      assert [{:trip, :no_source_available, %{failures: 8, movies: 3}}] = decisions
    end
  end

  describe "resolver_outdated" do
    test "trips quickly, on the second distinct movie" do
      {decisions, _window} = feed([{1, @outdated}, {1, @outdated}, {2, @outdated}])

      assert [:recorded, :recorded, {:trip, :resolver_outdated, %{movies: 2}}] = decisions
    end

    test "counts towards the rate rule alongside no_source_available" do
      events = [{1, @outdated}] ++ for id <- 2..5, do: {id, @no_source}
      {decisions, _window} = feed(events)

      assert {:trip, :no_source_available, %{failures: 5, movies: 5}} = List.last(decisions)
    end
  end

  describe "challenge_required" do
    @challenge {:error, :challenge_required}

    test "trips by the rate rule, not on sight" do
      {decisions, _window} = feed(for id <- 1..5, do: {id, @challenge})

      assert Enum.take(decisions, 4) == List.duplicate(:recorded, 4)
      assert {:trip, :challenge_required, %{failures: 5, movies: 5}} = List.last(decisions)
    end

    test "counts towards the rate rule alongside no_source_available" do
      events = [{1, @challenge}, {2, @challenge}] ++ for id <- 3..5, do: {id, @no_source}
      {decisions, _window} = feed(events)

      assert {:trip, :no_source_available, %{reasons: %{challenge_required: 2}}} =
               List.last(decisions)
    end
  end

  test "transient errors are recorded but never trip and never reset the streak" do
    transient = [
      {:error, :upstream_timeout},
      {:error, :provider_capacity_exhausted},
      {:error, :stream_resolution_failed},
      {:error, :some_new_resolver_error}
    ]

    events =
      for {result, id} <- Enum.with_index(List.duplicate(transient, 5) |> List.flatten()),
          do: {id, result}

    {decisions, window} = feed(events)
    assert Enum.all?(decisions, &(&1 == :recorded))
    assert %{transient: 20, failures: 0} = HealthWindow.summary(window, 20, @thresholds)

    interleaved =
      for id <- 1..5, result <- [@no_source, {:error, :upstream_timeout}], do: {id, result}

    {decisions, _window} = feed(interleaved)
    assert {:trip, :no_source_available, %{failures: 5}} = Enum.at(decisions, -2)
  end

  test "our own refusals are not upstream evidence" do
    {decisions, window} =
      feed([{1, {:error, :provider_disabled}}, {2, {:error, :provider_degraded}}])

    assert decisions == [:ignored, :ignored]

    assert %{successes: 0, failures: 0, transient: 0} =
             HealthWindow.summary(window, 2, @thresholds)
  end

  describe "recovery" do
    test "the first success after a trip asks for recovery, later ones do not" do
      {_decisions, tripped} = feed(for id <- 1..5, do: {id, @no_source})
      assert tripped.tripped?

      {decisions, window} = feed(tripped, [{6, success("a")}, {7, success("b")}], 5)
      assert [{:recover, _streak}, :recorded] = decisions
      refute window.tripped?
    end

    test "a cached session handed out again is not fresh evidence" do
      {_decisions, window} = feed([{1, success("cached")}])
      {_decisions, window} = feed(window, for(id <- 2..5, do: {id, @no_source}), 1)

      {decisions, window} = feed(window, [{1, success("cached")}], 5)
      assert decisions == [:ignored]
      assert %{streak: %{failures: 4}} = HealthWindow.summary(window, 6, @thresholds)
    end

    test "probe successes carry no session and always count" do
      {decisions, _window} = feed([{1, success()}, {1, success()}])
      assert decisions == [:recorded, :recorded]
    end
  end

  describe "bounds" do
    test "outcomes older than the window are forgotten" do
      thresholds = %{@thresholds | window_ms: 1_000}

      {_decisions, window} =
        feed(HealthWindow.new(), for(id <- 1..4, do: {id, @no_source}), 0, thresholds)

      {decisions, window} = feed(window, [{5, @no_source}], 2_000, thresholds)
      assert decisions == [:recorded]
      assert %{failures: 1} = HealthWindow.summary(window, 2_000, thresholds)
    end

    test "the window keeps only the newest entries" do
      thresholds = %{@thresholds | max_entries: 3}
      events = for id <- 1..10, do: {id, {:error, :upstream_timeout}}
      {_decisions, window} = feed(HealthWindow.new(), events, 0, thresholds)

      assert length(window.entries) == 3
      assert Enum.map(window.entries, & &1.movie_id) == [10, 9, 8]
    end
  end

  test "summary reports idle time and the movies failing since the last success" do
    window = HealthWindow.new()
    assert %{seconds_since_last_outcome: nil} = HealthWindow.summary(window, 0, @thresholds)

    {_decisions, window} = feed(window, [{1, success()}, {2, @no_source}, {3, @no_source}])

    assert %{seconds_since_last_outcome: 4, seconds_since_last_success: 4} =
             HealthWindow.summary(window, 4_002, @thresholds)

    assert HealthWindow.streak_movie_ids(window) == [3, 2]
  end
end
