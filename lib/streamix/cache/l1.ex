defmodule Streamix.Cache.L1 do
  @moduledoc """
  ConCache (in-memory, per-node) layer for `Streamix.Cache`.

  Wraps the raw ConCache calls so the hybrid `Streamix.Cache` facade
  doesn't have to know about `%ConCache.Item{}`, ETS access patterns, or
  the L1 TTL knobs. Only this module touches `:streamix_l1_cache`.
  """

  @cache :streamix_l1_cache
  @l1_ttl :timer.minutes(30)
  @l1_ttl_check_interval :timer.seconds(30)

  @doc "ConCache global TTL ceiling for L1 entries (matches the supervisor config)."
  def l1_ttl, do: @l1_ttl

  @doc "ConCache TTL-check interval (matches the supervisor config)."
  def l1_ttl_check_interval, do: @l1_ttl_check_interval

  @doc "Read a key from ConCache. `nil` on miss."
  def get(key), do: ConCache.get(@cache, key)

  @doc """
  Write a key, clipping its TTL to `@l1_ttl`. Drops nil values (we never
  want to memoise a miss in L1).
  """
  def put(_key, nil, _ttl_ms), do: :ok

  def put(key, value, ttl_ms) do
    if cacheable?(ttl_ms) do
      ConCache.put(@cache, key, %ConCache.Item{value: value, ttl: min(ttl_ms, @l1_ttl)})
    end

    :ok
  end

  @doc "Delete a single key."
  def delete(key), do: ConCache.delete(@cache, key)

  @doc "Stampede-prevention wrapper around `ConCache.get_or_store`."
  def get_or_store(key, fun) when is_function(fun, 0) do
    ConCache.get_or_store(@cache, key, fun)
  end

  @doc """
  L1 size + memory snapshot for the `Streamix.Cache.stats/0` dashboard.
  """
  def stats do
    ets_table = ConCache.ets(@cache)
    size = :ets.info(ets_table, :size)
    memory = :ets.info(ets_table, :memory) * :erlang.system_info(:wordsize)
    %{size: size, memory_bytes: memory}
  end

  @doc "Drop every entry. Used only by `invalidate_all/0`."
  def clear do
    @cache
    |> ConCache.ets()
    |> :ets.delete_all_objects()
  end

  @doc """
  L1 is only useful for entries whose TTL outlives the ConCache check
  interval — anything below it would be evicted before being read again.
  """
  def cacheable?(-1), do: true
  def cacheable?(ttl_ms) when ttl_ms > @l1_ttl_check_interval, do: true
  def cacheable?(_ttl_ms), do: false
end
