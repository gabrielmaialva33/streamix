defmodule Streamix.RuntimeBootstrap do
  @moduledoc false

  use GenServer

  alias Streamix.Gindex.{SingleFlight, Telemetry}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Streamix.Operations.setup()
    :ok = SingleFlight.setup()
    :ok = Telemetry.setup()

    {:ok, %{}}
  end
end
