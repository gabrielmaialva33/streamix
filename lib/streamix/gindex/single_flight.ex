defmodule Streamix.Gindex.SingleFlight do
  @moduledoc """
  Coalesces concurrent requests for the same key so only one underlying
  computation runs and every concurrent caller receives that single
  result.

  Sits in front of `Gindex.Client.list_folder_all/2` to keep two scan
  roots — or a worker re-running before the previous attempt finished —
  from opening parallel paginated walks against the same Cloudflare
  Worker token bucket. Without it, the upstream sees duplicate page-1
  fetches against the same path and starts cascading 500s.

  Implementation: ETS holds the leader pid per key (`:insert_new`
  serves as the claim). Followers subscribe to a Phoenix.PubSub topic
  derived from the key before checking ETS, so the leader's
  `broadcast` lands in their mailbox even if the leader runs to
  completion in microseconds. The leader publishes one result, every
  subscriber receives it, the ETS row is deleted.
  """

  @table :gindex_single_flight
  @pubsub Streamix.PubSub
  @default_timeout 600_000

  @doc """
  Initializes the ETS table at application boot. Called from
  `Streamix.Application.start/2`.
  """
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Runs `fun` exactly once across concurrent callers sharing `key`.

  Concurrent calls block until the leader returns, then receive the
  same result. If the leader crashes, the next caller takes over.
  """
  @spec execute(term(), (-> result), timeout()) :: result when result: term()
  def execute(key, fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    setup()
    topic = topic_for(key)

    # Subscribe FIRST so we never miss the leader's broadcast even when
    # the leader's run is faster than our claim attempt.
    :ok = Phoenix.PubSub.subscribe(@pubsub, topic)

    try do
      case claim(key) do
        :leader ->
          run_as_leader(key, topic, fun)

        {:follower, leader_pid} ->
          wait_for_leader(key, leader_pid, fun, timeout)
      end
    after
      Phoenix.PubSub.unsubscribe(@pubsub, topic)
      drain_pubsub_messages(topic)
    end
  end

  # Internals

  defp topic_for(key), do: "gindex:single_flight:#{:erlang.phash2(key)}"

  defp claim(key) do
    case :ets.insert_new(@table, {key, self()}) do
      true -> :leader
      false -> claim_existing(key)
    end
  end

  defp claim_existing(key) do
    case :ets.lookup(@table, key) do
      [{^key, leader_pid}] when is_pid(leader_pid) -> follow_or_reclaim(key, leader_pid)
      _ -> claim(key)
    end
  end

  defp follow_or_reclaim(key, leader_pid) when is_pid(leader_pid) do
    if Process.alive?(leader_pid) do
      {:follower, leader_pid}
    else
      # Stale row from a crashed leader — wipe and re-claim.
      :ets.delete(@table, key)
      claim(key)
    end
  end

  defp run_as_leader(key, topic, fun) do
    result =
      try do
        {:ok, fun.()}
      rescue
        e -> {:raised, e, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    Phoenix.PubSub.broadcast(@pubsub, topic, {:single_flight, key, result})
    :ets.delete(@table, key)

    case result do
      {:ok, value} -> value
      {:raised, e, stack} -> reraise e, stack
      {:caught, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp wait_for_leader(key, leader_pid, fun, timeout) do
    ref = Process.monitor(leader_pid)

    try do
      receive do
        {:single_flight, ^key, {:ok, value}} ->
          value

        {:single_flight, ^key, {:raised, e, stack}} ->
          reraise e, stack

        {:single_flight, ^key, {:caught, kind, reason, stack}} ->
          :erlang.raise(kind, reason, stack)

        {:DOWN, ^ref, :process, ^leader_pid, _reason} ->
          # Leader crashed before broadcasting. Re-attempt the claim.
          execute(key, fun, timeout)
      after
        timeout ->
          {:error, :single_flight_timeout}
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp drain_pubsub_messages(topic) do
    receive do
      {:single_flight, _key, _payload} -> drain_pubsub_messages(topic)
    after
      0 -> :ok
    end
  end
end
