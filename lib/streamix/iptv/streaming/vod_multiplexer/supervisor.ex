defmodule Streamix.Iptv.Streaming.VodMultiplexer.Supervisor do
  @moduledoc """
  DynamicSupervisor for in-flight VOD block downloads.

  Each child owns one `{content_key, block_index}` and lives only as long as
  that download; viewers arriving mid-flight attach to the existing child
  rather than opening a second upstream connection.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
