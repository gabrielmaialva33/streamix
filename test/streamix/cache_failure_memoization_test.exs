defmodule Streamix.CacheFailureMemoizationTest do
  @moduledoc """
  `Cache.fetch/3` used to store whatever the compute function returned, so an
  `{:error, _}` landed in L1 and Redis under the *success* TTL. On the TMDB keys
  that TTL is 24 hours: one rate-limited minute upstream was replayed to every
  caller for a day, and the enrichment workers read it as an answer.

  These pin the rule that a failure is never an answer worth keeping.
  """
  use ExUnit.Case, async: false

  alias Streamix.Cache

  setup do
    key = "test:failure-memoization:#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.delete(key) end)
    %{key: key}
  end

  defp counting_fun(results) do
    agent = start_supervised!({Agent, fn -> results end})

    fn ->
      Agent.get_and_update(agent, fn
        [head | rest] -> {head, rest}
        [] -> {:exhausted, []}
      end)
    end
  end

  test "an error is not served again from cache", %{key: key} do
    fun = counting_fun([{:error, :rate_limited}, {:ok, "real value"}])

    assert {:error, :rate_limited} = Cache.fetch(key, 3600, fun)

    assert {:ok, "real value"} = Cache.fetch(key, 3600, fun),
           "the second caller got the memoised failure instead of recomputing"
  end

  test "a success is still cached", %{key: key} do
    fun = counting_fun([{:ok, "first"}, {:ok, "second"}])

    assert {:ok, "first"} = Cache.fetch(key, 3600, fun)

    assert {:ok, "first"} = Cache.fetch(key, 3600, fun),
           "caching a successful value must keep working"
  end

  test "an error does not survive into a later success", %{key: key} do
    fun = counting_fun([{:error, :timeout}, {:error, :unauthorized}, {:ok, "eventual"}])

    assert {:error, :timeout} = Cache.fetch(key, 3600, fun)
    assert {:error, :unauthorized} = Cache.fetch(key, 3600, fun)
    assert {:ok, "eventual"} = Cache.fetch(key, 3600, fun)
    assert {:ok, "eventual"} = Cache.fetch(key, 3600, fun)
  end

  # The L1 tier is bypassed for long TTLs, so the rule has to hold on both
  # paths — the TMDB keys are exactly the long-TTL ones.
  test "the rule holds on the no-L1 path as well", %{key: key} do
    long_ttl = 86_400
    fun = counting_fun([{:error, :rate_limited}, {:ok, "real value"}])

    assert {:error, :rate_limited} = Cache.fetch(key, long_ttl, fun)
    assert {:ok, "real value"} = Cache.fetch(key, long_ttl, fun)
  end
end
