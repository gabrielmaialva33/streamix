defmodule Streamix.Workers.RebuildStationsWorkerTest do
  use Streamix.DataCase, async: false

  import ExUnit.CaptureLog

  alias Streamix.Programming
  alias Streamix.Programming.Lineup
  alias Streamix.Workers.RebuildStationsWorker

  test "syncs the lineup even when no program can be built" do
    # No embedding provider in tests: discovery fails, stations stay empty
    # and off the list, and the job still succeeds.
    capture_log(fn ->
      assert :ok = RebuildStationsWorker.perform(%Oban.Job{args: %{"only_empty" => true}})
    end)

    for %{slug: slug} <- Lineup.stations(), do: assert(Programming.get_station(slug))
    assert Programming.list_stations() == []
  end

  test "runs on the ai queue and is unique per args" do
    changeset = RebuildStationsWorker.new(%{"only_empty" => true})
    assert Ecto.Changeset.get_field(changeset, :queue) == "ai"
    assert :args in Ecto.Changeset.get_field(changeset, :unique).fields
  end
end
