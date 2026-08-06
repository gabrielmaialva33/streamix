defmodule Streamix.Gindex.RequestBudget do
  @moduledoc false

  @process_key {__MODULE__, :state}

  @doc "Runs a scan slice with a process-local outbound request ceiling."
  @spec run(pos_integer(), (-> result)) :: result when result: term()
  def run(limit, fun) when is_integer(limit) and limit > 0 and is_function(fun, 0) do
    previous = Process.get(@process_key)
    Process.put(@process_key, %{limit: limit, count: 0})

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

      %{limit: limit, count: count} when count < limit ->
        Process.put(@process_key, %{limit: limit, count: count + 1})
        :ok

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

  defp restore(nil), do: Process.delete(@process_key)
  defp restore(previous), do: Process.put(@process_key, previous)
end
