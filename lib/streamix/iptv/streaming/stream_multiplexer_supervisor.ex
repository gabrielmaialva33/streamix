defmodule Streamix.Iptv.StreamMultiplexerSupervisor do
  @moduledoc """
  DynamicSupervisor for StreamMultiplexer processes.

  Each child manages a single upstream connection for a specific live channel,
  fanning out chunks to demand-driven downstream subscribers.
  """
  use DynamicSupervisor

  alias Streamix.Iptv.StreamMultiplexer

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_child(args) do
    DynamicSupervisor.start_child(__MODULE__, {StreamMultiplexer, args})
  end

  @doc """
  Stops one idle multiplexer of `provider_id` (no subscribers, waiting out its
  grace period) so its upstream lease can be reused by the caller.

  Returns `:reclaimed` when a lease was freed and `:none` otherwise. Pass
  `except:` to skip the caller's own multiplexer process.
  """
  @spec reclaim_idle(integer() | nil, keyword()) :: :reclaimed | :none
  def reclaim_idle(provider_id, opts \\ [])

  def reclaim_idle(nil, _opts), do: :none

  def reclaim_idle(provider_id, opts) do
    except = Keyword.get(opts, :except, self())

    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:none, fn
      {_, pid, :worker, _} when is_pid(pid) and pid != except ->
        case StreamMultiplexer.reclaim_if_idle(pid, provider_id) do
          :reclaimed -> :reclaimed
          :busy -> nil
        end

      _child ->
        nil
    end)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
