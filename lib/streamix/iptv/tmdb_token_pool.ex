defmodule Streamix.Iptv.TmdbTokenPool do
  @moduledoc """
  Round-robin token pool for TMDB profiles that expose an `:api_tokens`
  list. Callers pick a token with `next/1` before issuing a request; when
  a token hits TMDB's per-token rate ceiling, `next_after/2` returns a
  different one so the retry can keep moving.

  Rotation state lives in an `:atomics` counter stored in
  `:persistent_term` — crash-safe, GC-free, no GenServer in the hot path.
  """

  @counter_key {__MODULE__, :counter}

  @spec next(atom()) :: String.t() | nil
  def next(profile) do
    case tokens(profile) do
      [] -> nil
      [single] -> single
      list -> pick(list)
    end
  end

  @doc """
  Pick a token different from `skip` when possible. Falls back to the
  regular rotation if `skip` is the only token configured.
  """
  @spec next_after(atom(), String.t() | nil) :: String.t() | nil
  def next_after(profile, nil), do: next(profile)

  def next_after(profile, skip) do
    case tokens(profile) do
      [] ->
        nil

      [single] ->
        single

      list ->
        case Enum.reject(list, &(&1 == skip)) do
          [] -> pick(list)
          remaining -> pick(remaining)
        end
    end
  end

  @doc false
  @spec tokens(atom()) :: [String.t()]
  def tokens(profile) do
    default = Application.get_env(:streamix, :tmdb, [])
    override = Application.get_env(:streamix, :"tmdb_#{profile}", [])
    cfg = Keyword.merge(default, override)

    configured =
      case cfg[:api_tokens] do
        list when is_list(list) and list != [] -> list
        _ -> List.wrap(cfg[:api_token])
      end

    Enum.filter(configured, &(is_binary(&1) and &1 != ""))
  end

  defp pick(list) do
    idx = :atomics.add_get(counter(), 1, 1)
    Enum.at(list, rem(idx - 1, length(list)))
  end

  defp counter do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
