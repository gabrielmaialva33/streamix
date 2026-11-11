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

  describe "grouped history across providers" do
    test "one card per title, whatever provider each episode or copy came from" do
      owner = user_fixture()
      key = library_key_fixture(owner)

      [first, second] =
        for name <- ["Provedor A", "Provedor B"],
            do: provider_fixture(owner, %{name: name, visibility: "global", is_system: true})

      episode = fn provider, series_attrs, number ->
        series = series_content_fixture(provider, series_attrs)
        season = Repo.insert!(%Season{series_id: series.id, season_number: 1, name: "T1"})

        %Episode{}
        |> Episode.changeset(%{
          episode_id: System.unique_integer([:positive]),
          episode_num: number,
          title: "Episódio #{number}",
          season_id: season.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()
      end

      # Same series by TMDB id, and an untracked one matched by its title.
      by_tmdb = %{name: "Prazer Máximo", title: nil, tmdb_id: "250000"}

      for {provider, attrs, n} <- [
            {first, by_tmdb, 1},
            {second, by_tmdb, 2},
            {first, %{name: "Cabo do Medo", title: nil, tmdb_id: nil}, 1},
            {second, %{name: "Cabo do Medo [L]", title: nil, tmdb_id: nil}, 2}
          ] do
        {:ok, _} = History.add(key, "episode", episode.(provider, attrs, n).id)
      end

      for provider <- [first, second] do
        movie = movie_fixture(provider, %{name: "Holy Spider", tmdb_id: "736526"})
        {:ok, _} = History.add(key, "movie", movie.id)
      end

      cards = History.list(key, group_episodes: true, limit: 10)

      assert length(cards) == 3

      assert cards |> Enum.filter(&(&1.content_type == "episode")) |> Enum.map(& &1.episode_count) ==
               [2, 2]

      assert History.count_by_type(key) == %{"episode" => 4, "movie" => 2}

      movie_card = Enum.find(cards, &(&1.content_type == "movie"))
      assert {2, nil} = History.remove(key, movie_card.id, group_episodes: true)

      series_card = Enum.find(cards, &(&1.content_type == "episode"))
      assert {2, nil} = History.remove(key, series_card.id, group_episodes: true)
      assert length(History.list(key, group_episodes: true)) == 1
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
