defmodule Streamix.Programming.Supervisor do
  @moduledoc """
  The station registry, the dynamic supervisor of station servers and, when
  `config :streamix, Streamix.Programming, autostart: true`, a one-off task
  that puts every active station on air at boot.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: Streamix.Programming.Registry},
        {DynamicSupervisor, name: Streamix.Programming.StationSupervisor, strategy: :one_for_one}
      ] ++ autostart()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp autostart do
    if Streamix.Programming.autostart?(),
      do: [{Task, &Streamix.Programming.ensure_on_air/0}],
      else: []
  end
end
