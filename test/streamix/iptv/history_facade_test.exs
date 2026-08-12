defmodule Streamix.Iptv.HistoryFacadeTest do
  use Streamix.DataCase, async: true
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv
  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Workers.UpdateUserProfileWorker

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  # =============================================================================
  # Watch History (WatchProgress)
  # =============================================================================

  describe "list_watch_history/2" do
    test "returns watch progress for a user" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)
      watch_history_fixture(user, channel, 120)

      history = Iptv.list_watch_history(user.id)

      assert length(history) == 1
      assert hd(history).content_id == channel.id
      assert hd(history).content_type == "live_channel"
      assert hd(history).duration_seconds == 120
    end

    test "returns all watch progress entries for user" do
      user = user_fixture()
      provider = provider_fixture(user)
      ch1 = channel_fixture(provider, %{name: "First"})
      ch2 = channel_fixture(provider, %{name: "Second"})
      watch_history_fixture(user, ch1)
      watch_history_fixture(user, ch2)

      history = Iptv.list_watch_history(user.id)
      assert length(history) == 2

      content_ids = Enum.map(history, & &1[:content_id]) |> MapSet.new()
      assert MapSet.member?(content_ids, ch1.id)
      assert MapSet.member?(content_ids, ch2.id)
    end
  end

  describe "list_home_history/2" do
    test "returns lightweight history cards for home" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "History Movie",
          stream_icon: "http://example.com/history-movie.jpg"
        })

      {:ok, _entry} =
        Iptv.add_watch_history(user.id, "movie", movie.id, %{
          progress_seconds: 42,
          duration_seconds: 120
        })

      [entry] = Iptv.list_home_history(user.id, limit: 6)

      assert entry.content_type == "movie"
      assert entry.content_id == movie.id
      assert entry.content_name == "History Movie"
      assert entry.content_icon == "http://example.com/history-movie.jpg"
      assert entry.progress_seconds == 42
      assert entry.duration_seconds == 120
      assert %DateTime{} = entry.watched_at
      refute Map.has_key?(entry, :catalog_item)

      assert Map.keys(entry) |> Enum.sort() == [
               :content_icon,
               :content_id,
               :content_name,
               :content_type,
               :duration_seconds,
               :id,
               :progress_seconds,
               :watched_at
             ]
    end
  end

  describe "add_watch_history/3" do
    test "adds watch progress entry" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %{} = entry} =
               Iptv.add_watch_history(user.id, "live_channel", channel.id, %{
                 duration_seconds: 300
               })

      assert entry.duration_seconds == 300
      assert entry.user_id == user.id
      assert entry.catalog_item_id == channel.catalog_item_id

      assert_enqueued(
        worker: UpdateUserProfileWorker,
        args: %{user_id: user.id}
      )
    end

    test "does not enqueue profile refresh after a rejected write" do
      user = user_fixture()

      assert {:error, _changeset} =
               Iptv.add_watch_history(user.id, "movie", -1, %{duration_seconds: 300})

      refute_enqueued(
        worker: UpdateUserProfileWorker,
        args: %{user_id: user.id}
      )
    end
  end

  describe "clear_watch_history/1" do
    test "clears all watch progress for user" do
      user = user_fixture()
      provider = provider_fixture(user)

      for _ <- 1..5 do
        ch = channel_fixture(provider)
        watch_history_fixture(user, ch)
      end

      Repo.delete_all(Oban.Job)
      refute_enqueued(worker: UpdateUserProfileWorker)

      assert {:ok, 5} = Iptv.clear_watch_history(user.id)
      assert Iptv.list_watch_history(user.id) == []

      assert_enqueued(
        worker: UpdateUserProfileWorker,
        args: %{user_id: user.id}
      )
    end
  end

  describe "get_series_progress_map/2" do
    test "returns series progress keyed by series id using the latest watched episode" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider, %{name: "Progress Series"})

      season =
        %Season{}
        |> Season.changeset(%{
          season_number: 1,
          name: "Season 1",
          series_id: series.id
        })
        |> Repo.insert!()

      episode_one =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 201,
          title: "Episode 1",
          episode_num: 1,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      episode_two =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 202,
          title: "Episode 2",
          episode_num: 2,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      {:ok, _} =
        Iptv.add_watch_history(user.id, "episode", episode_one.id, %{
          progress_seconds: 30,
          duration_seconds: 120
        })

      {:ok, _} =
        Iptv.add_watch_history(user.id, "episode", episode_two.id, %{
          progress_seconds: 90,
          duration_seconds: 180
        })

      assert Iptv.get_series_progress_map(user.id, [series.id]) == %{series.id => 0.5}
    end
  end
end
