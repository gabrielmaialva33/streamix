defmodule Streamix.Workers.CleanupQoeEventsWorkerTest do
  use Streamix.DataCase, async: true

  import Ecto.Query

  alias Streamix.Qoe
  alias Streamix.Qoe.Event
  alias Streamix.Repo
  alias Streamix.Workers.CleanupQoeEventsWorker

  test "removes expired samples while retaining recent ones" do
    expired_batch = Ecto.UUID.generate()
    recent_batch = Ecto.UUID.generate()

    assert {:ok, %{accepted: 1, batch_id: ^expired_batch}} =
             Qoe.ingest(nil, expired_batch, [%{"kind" => "playback"}])

    Event
    |> where([event], event.batch_id == ^expired_batch)
    |> Repo.update_all(
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)]
    )

    assert {:ok, %{accepted: 1, batch_id: ^recent_batch}} =
             Qoe.ingest(nil, recent_batch, [%{"kind" => "pwa"}])

    assert :ok = CleanupQoeEventsWorker.perform(%Oban.Job{args: %{}})
    assert [%Event{batch_id: ^recent_batch}] = Repo.all(Event)
  end
end
