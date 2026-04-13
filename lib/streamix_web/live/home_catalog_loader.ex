defmodule StreamixWeb.HomeCatalogLoader do
  @moduledoc false

  @default_timeout 15_000

  @spec load(%{required(term()) => (-> term())} | keyword((-> term())), keyword()) :: map()
  def load(fetchers, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, map_size(Map.new(fetchers)))
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    fetchers
    |> Enum.to_list()
    |> Task.async_stream(fn {key, fun} -> {key, fun.()} end,
      ordered: false,
      timeout: timeout,
      max_concurrency: max_concurrency
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, value}}, acc ->
        Map.put(acc, key, value)

      {:exit, reason}, _acc ->
        exit(reason)
    end)
  end
end
