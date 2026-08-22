defmodule Streamix.Workers.CleanupWatchPartyRoomsWorkerTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.WatchParty.Room
  alias Streamix.Workers.CleanupWatchPartyRoomsWorker

  test "expires abandoned active rooms and purges ended rooms past retention" do
    user = user_fixture()
    provider = provider_fixture(user)
    active_movie = movie_fixture(provider, %{name: "Abandoned Party"})
    ended_movie = movie_fixture(provider, %{name: "Old Ended Party"})

    active_room =
      room_fixture(user, active_movie)
      |> Ecto.Changeset.change(last_activity_at: DateTime.add(DateTime.utc_now(), -31, :minute))
      |> Repo.update!()

    ended_room =
      room_fixture(user, ended_movie)
      |> Room.end_changeset("test_retention")
      |> Ecto.Changeset.change(
        ended_at:
          DateTime.utc_now()
          |> DateTime.add(-91, :day)
          |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    assert :ok = CleanupWatchPartyRoomsWorker.perform(%Oban.Job{})

    expired = Repo.get!(Room, active_room.id)
    assert expired.status == "ended"
    assert expired.ended_reason == "inactive_cleanup"
    refute Repo.get(Room, ended_room.id)
  end

  defp room_fixture(user, movie) do
    %Room{}
    |> Room.create_changeset(%{
      host_user_id: user.id,
      catalog_item_id: movie.catalog_item_id,
      source_type: "movie",
      source_id: movie.id
    })
    |> Repo.insert!()
  end
end
