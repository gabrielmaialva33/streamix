defmodule Streamix.Iptv.HistoryFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Episode, Season}

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

      history = Iptv.list_watch_history(library_key_fixture(user))

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

      history = Iptv.list_watch_history(library_key_fixture(user))
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
        Iptv.add_watch_history(library_key_fixture(user), "movie", movie.id, %{
          progress_seconds: 42,
          duration_seconds: 120
        })

      [entry] = Iptv.list_home_history(library_key_fixture(user), limit: 6)

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
               :tmdb_id,
               :watched_at
             ]
    end
  end

  describe "list_home_history/2 for episodes" do
    test "carries the series and the episode's position" do
      user = user_fixture()
      provider = provider_fixture(user)

      series =
        series_content_fixture(provider, %{
          name: "Dawson's Creek",
          cover: "http://example.com/dc.jpg"
        })

      season =
        %Season{}
        |> Season.changeset(%{season_number: 1, name: "Season 1", series_id: series.id})
        |> Repo.insert!()

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 302,
          title: "Dawson's Creek - S01E02 - Piloto",
          episode_num: 2,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      {:ok, _entry} =
        Iptv.add_watch_history(library_key_fixture(user), "episode", episode.id, %{
          progress_seconds: 42,
          duration_seconds: 120
        })

      [entry] = Iptv.list_home_history(library_key_fixture(user), limit: 6)

      assert entry.content_id == episode.id
      assert entry.series_name == "Dawson's Creek"
      assert entry.season_number == 1
      assert entry.episode_number == 2
      assert entry.content_icon == "http://example.com/dc.jpg"
    end
  end

  describe "add_watch_history/3" do
    test "adds watch progress entry" do
      user = user_fixture()
      provider = provider_fixture(user)
      channel = channel_fixture(provider)

      assert {:ok, %{} = entry} =
               Iptv.add_watch_history(library_key_fixture(user), "live_channel", channel.id, %{
                 duration_seconds: 300
               })

      assert entry.duration_seconds == 300
      assert entry.user_id == user.id
      assert entry.catalog_item_id == channel.catalog_item_id
    end

    test "rejects content that does not exist" do
      user = user_fixture()

      assert {:error, changeset} =
               Iptv.add_watch_history(library_key_fixture(user), "movie", -1, %{
                 duration_seconds: 300
               })

      assert {"is invalid", _} = changeset.errors[:content_id]
      assert Iptv.list_watch_history(library_key_fixture(user)) == []
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

      assert {:ok, 5} = Iptv.clear_watch_history(library_key_fixture(user))
      assert Iptv.list_watch_history(library_key_fixture(user)) == []
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
        Iptv.add_watch_history(library_key_fixture(user), "episode", episode_one.id, %{
          progress_seconds: 30,
          duration_seconds: 120
        })

      {:ok, _} =
        Iptv.add_watch_history(library_key_fixture(user), "episode", episode_two.id, %{
          progress_seconds: 90,
          duration_seconds: 180
        })

      assert Iptv.get_series_progress_map(library_key_fixture(user), [series.id]) == %{
               series.id => 0.5
             }
    end
  end
end
