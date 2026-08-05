defmodule Streamix.Iptv.HistoryTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv.{Episode, History, Season}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

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
        History.add(user.id, "movie", movie.id, %{
          progress_seconds: 50,
          duration_seconds: 100,
          completed: true
        })

      [entry] = History.list_for_analytics(user.id, content_type: "movie", limit: 10)

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
        History.add(user.id, "movie", movie.id, %{
          progress_seconds: 50,
          duration_seconds: 100
        })

      Repo.delete!(movie)

      assert History.list_for_analytics(user.id, limit: 10) == []
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

      {:ok, _history} = History.add(user.id, "episode", episode.id)

      assert History.list_for_analytics(user.id, show_adult: false) == []
      assert [entry] = History.list_for_analytics(user.id, show_adult: true)
      assert entry.content_id == episode.id
      assert entry.series_id == series.id
    end
  end
end
