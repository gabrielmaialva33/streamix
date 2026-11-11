defmodule Streamix.Gindex.RequestBudget do
  @moduledoc false

  @process_key {__MODULE__, :state}

  @doc """
  Runs a scan slice with a process-local outbound request ceiling.

  `:deadline_ms` also ends the slice once that much time has passed, at the
  next request it would make. A request ceiling alone cannot bound a slice's
  duration: one Worker folder that answers 500 every time costs about ten
  minutes of capped retries across three endpoints, and a few of them kept a
  1,500-request slice past Oban's two-hour timeout, which killed the job and
  spent one of its attempts.
  """
  @spec run(pos_integer(), (-> result), keyword()) :: result when result: term()
  def run(limit, fun, opts \\ []) when is_integer(limit) and limit > 0 and is_function(fun, 0) do
    previous = Process.get(@process_key)

    deadline =
      case Keyword.get(opts, :deadline_ms) do
        ms when is_integer(ms) and ms >= 0 -> System.monotonic_time(:millisecond) + ms
        _none -> nil
      end

    Process.put(@process_key, %{limit: limit, count: 0, deadline: deadline})

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc "Reserves one request from the current scan slice."
  @spec consume() :: :ok | {:error, {:slice_exhausted, non_neg_integer()}}
  def consume do
    case Process.get(@process_key) do
      nil ->
        :ok

      %{limit: limit, count: count, deadline: deadline} = state when count < limit ->
        if past?(deadline) do
          {:error, {:slice_exhausted, count}}
        else
          Process.put(@process_key, %{state | count: count + 1})
          :ok
        end

      %{count: count} ->
        {:error, {:slice_exhausted, count}}
    end
  end

  @doc false
  def current_count do
    case Process.get(@process_key) do
      %{count: count} -> count
      nil -> 0
    end
  end

  defp past?(nil), do: false
  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp restore(nil), do: Process.delete(@process_key)
  defp restore(previous), do: Process.put(@process_key, previous)
end
