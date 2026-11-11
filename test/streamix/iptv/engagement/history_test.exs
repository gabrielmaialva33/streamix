defmodule Streamix.Iptv.HistoryTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.{Episode, History, Season}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "grouped history" do
    test "groups across pages, preserves other content and removes only the owner's series" do
      owner = user_fixture()
      stranger = user_fixture()
      key = library_key_fixture(owner)
      stranger_key = library_key_fixture(stranger)
      provider = provider_fixture(owner, %{visibility: "global", is_system: true})
      series = series_content_fixture(provider)
      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, name: "Season 1"})
      movie = movie_fixture(provider)
      {:ok, movie_entry} = History.add(key, "movie", movie.id)

      episodes =
        for number <- 1..3 do
          episode =
            %Episode{}
            |> Episode.changeset(%{
              episode_id: System.unique_integer([:positive]),
              episode_num: number,
              title: "Episode #{number}",
              season_id: season.id,
              catalog_item_id: catalog_item_fixture("episode", provider.id).id
            })
            |> Repo.insert!()

          {:ok, entry} = History.add(key, "episode", episode.id)
          {:ok, _} = History.add(stranger_key, "episode", episode.id)
          {episode, entry}
        end

      {latest, latest_entry} = List.last(episodes)
      [group] = History.list(key, group_episodes: true, limit: 1)
      assert group.content_id == latest.id
      assert group.episode_count == 3
      assert group.series_id == series.id
      assert group.watched_at == latest_entry.watched_at
      assert [remaining] = History.list(key, group_episodes: true, limit: 1, offset: 1)
      assert remaining.id == movie_entry.id
      assert length(History.list(key)) == 4
      assert History.count_by_type(key) == %{"episode" => 3, "movie" => 1}

      assert {0, nil} = History.remove(stranger_key, group.id, group_episodes: true)
      assert {3, nil} = History.remove(key, group.id, group_episodes: true)
      assert [%{id: id}] = History.list(key)
      assert id == movie_entry.id
      assert length(History.list(stranger_key)) == 3
      assert {0, nil} = History.remove(key, group.id, group_episodes: true)
      assert {1, nil} = History.remove(key, movie_entry.id, group_episodes: true)
    end
  end

  describe "list_for_analytics/2" do
    test "returns lightweight analytics entries without catalog preloads" do
      user = user_fixture()
      provider = provider_fixture(user)

      movie =
        movie_fixture(provider, %{
          name: "Analytics Movie",
          stream_icon: "http://example.com/a.jpg"
        })

      {:ok, _entry} =
        History.add(library_key_fixture(user), "movie", movie.id, %{
          progress_seconds: 50,
          duration_seconds: 100,
          completed: true
        })

      [entry] =
        History.list_for_analytics(library_key_fixture(user), content_type: "movie", limit: 10)

      assert entry.content_type == "movie"
      assert entry.content_id == movie.id
      assert is_nil(entry.series_id)
      assert entry.progress_seconds == 50
      assert entry.duration_seconds == 100
      assert entry.completed == true
      assert %DateTime{} = entry.watched_at
      refute Map.has_key?(entry, :catalog_item)

      assert Map.keys(entry) |> Enum.sort() == [
               :completed,
               :content_id,
               :content_type,
               :duration_seconds,
               :progress_seconds,
               :series_id,
               :watched_at
             ]
    end

    test "omits progress whose content row was deleted" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider)

      {:ok, _entry} =
        History.add(library_key_fixture(user), "movie", movie.id, %{
          progress_seconds: 50,
          duration_seconds: 100
        })

      Repo.delete!(movie)

      assert History.list_for_analytics(library_key_fixture(user), limit: 10) == []
    end

    test "maps episodes to their parent series and inherits its adult policy" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider, %{name: "Adult parent series"})

      season =
        %Season{}
        |> Season.changeset(%{season_number: 1, name: "Season 1", series_id: series.id})
        |> Repo.insert!()

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 401,
          title: "Adult inherited episode",
          episode_num: 1,
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Adult series policy",
          type: "series",
          external_id: "adult-series-policy",
          is_adult: true
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: series.catalog_item_id, category_id: category.id}
      ])

      {:ok, _history} = History.add(library_key_fixture(user), "episode", episode.id)

      assert History.list_for_analytics(library_key_fixture(user), show_adult: false) == []

      assert History.list(library_key_fixture(user), group_episodes: true, show_adult: false) ==
               []

      assert [%{episode_count: 1}] =
               History.list(library_key_fixture(user), group_episodes: true, show_adult: true)

      assert [entry] = History.list_for_analytics(library_key_fixture(user), show_adult: true)
      assert entry.content_id == episode.id
      assert entry.series_id == series.id
    end
  end
end
