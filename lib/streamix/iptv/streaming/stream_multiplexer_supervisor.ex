defmodule Streamix.Iptv.StreamMultiplexerSupervisor do
  @moduledoc """
  DynamicSupervisor for StreamMultiplexer processes.

  Each child manages a single upstream connection for a specific live channel,
  fanning out chunks to demand-driven downstream subscribers.
  """
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_child(args) do
    DynamicSupervisor.start_child(__MODULE__, {Streamix.Iptv.StreamMultiplexer, args})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
