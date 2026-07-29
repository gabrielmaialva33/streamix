defmodule Streamix.Iptv.StreamLookupFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Episode, Season}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "stream lookup queries" do
    test "get_movie_for_stream/1 only preloads provider" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{stream_icon: "http://example.com/poster.jpg"})

      result = Iptv.get_movie_for_stream(movie.id)

      assert result.id == movie.id
      assert Ecto.assoc_loaded?(result.provider)
      refute Ecto.assoc_loaded?(result.genres)
      refute Ecto.assoc_loaded?(result.credits)
      refute Ecto.assoc_loaded?(result.assets)
    end

    test "get_episode_for_stream/1 loads provider context without unrelated preloads" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider)

      season =
        %Season{}
        |> Season.changeset(%{
          season_number: 1,
          name: "Season 1",
          series_id: series.id
        })
        |> Repo.insert!()

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: 101,
          title: "Episode 1",
          episode_num: 1,
          season_id: season.id,
          provider_id: provider.id,
          catalog_item_id: catalog_item_fixture("episode", provider.id).id
        })
        |> Repo.insert!()

      result = Iptv.get_episode_for_stream(episode.id)

      assert result.id == episode.id
      assert Ecto.assoc_loaded?(result.season)
      assert Ecto.assoc_loaded?(result.season.series)
      assert Ecto.assoc_loaded?(result.season.series.provider)
      refute Ecto.assoc_loaded?(result.season.series.assets)
    end
  end

  # =============================================================================
  # Categories
  # =============================================================================

  describe "list_categories/1" do
    test "returns unique categories for a provider" do
      user = user_fixture()
      provider = provider_fixture(user)

      Repo.insert!(%Streamix.Iptv.Category{
        provider_id: provider.id,
        name: "News",
        type: "live",
        external_id: "1"
      })

      Repo.insert!(%Streamix.Iptv.Category{
        provider_id: provider.id,
        name: "Sports",
        type: "live",
        external_id: "2"
      })

      categories = Iptv.list_categories(provider.id)

      names = Enum.map(categories, & &1.name)
      assert "News" in names
      assert "Sports" in names
      assert length(categories) == 2
    end
  end
end
