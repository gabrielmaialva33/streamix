defmodule Streamix.Workers.RebuildStationsWorker do
  @moduledoc """
  Keeps the 24h stations on air: syncs the shipped lineup, builds programs
  and starts a server for every station that has one.

  Daily it rebuilds every program, so new titles and fresher tags enter the
  loop (the schedule restarts then, in the audience's quietest hour). At boot
  (`%{"only_empty" => true}`) it only fills stations that have no program
  yet, leaving running schedules where they are.
  """

  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [period: :timer.minutes(30), fields: [:worker, :args], states: :incomplete]

  alias Streamix.Programming

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    :ok = Programming.sync_lineup()
    rebuilt = Programming.rebuild_programs(only_empty: Map.get(args, "only_empty", false))
    :ok = Programming.ensure_on_air()

    Logger.info("[Programming] stations rebuilt #{inspect(rebuilt)}")
    :ok
  end
end
