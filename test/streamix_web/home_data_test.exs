defmodule StreamixWeb.HomeDataTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Iptv
  alias StreamixWeb.HomeData

  setup do
    Cache.invalidate_all()
    :ok
  end

  describe "toggle_content_favorite/3" do
    test "persists movie favorites from home card previews and refreshes home state" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{title: "Preview Favorite"})

      socket = home_socket(user, featured: {:movie, movie})

      refute Iptv.favorite?(user.id, "movie", movie.id)

      socket = HomeData.toggle_content_favorite(socket, "movie", Integer.to_string(movie.id))

      assert Iptv.favorite?(user.id, "movie", movie.id)
      assert MapSet.member?(socket.assigns.movie_favorites_map, movie.id)
      assert socket.assigns.featured_favorite

      assert Enum.any?(socket.assigns.favorites, fn favorite ->
               favorite.content_type == "movie" and favorite.content_id == movie.id
             end)
    end

    test "removes existing series favorites from home card previews" do
      user = user_fixture()
      provider = provider_fixture(user)
      series = series_content_fixture(provider, %{title: "Favorited Series"})

      {:ok, _favorite} = Iptv.add_favorite(user.id, "series", series.id)

      socket =
        home_socket(user,
          featured: {:series, series},
          series_favorites_map: MapSet.new([series.id])
        )

      socket = HomeData.toggle_content_favorite(socket, :series, series.id)

      refute Iptv.favorite?(user.id, "series", series.id)
      refute MapSet.member?(socket.assigns.series_favorites_map, series.id)
      refute socket.assigns.featured_favorite
    end

    test "keeps adult favorites hidden when refreshing the home rail" do
      user = user_fixture()
      provider = provider_fixture(user)
      regular = movie_fixture(provider, %{title: "Regular Favorite"})
      adult = movie_fixture(provider, %{title: "Adult Favorite"})

      adult_category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Adultos",
          type: "vod",
          external_id: "adult-home-refresh",
          is_adult: true
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: adult.catalog_item_id, category_id: adult_category.id}
      ])

      {:ok, _favorite} = Iptv.add_favorite(user.id, "movie", adult.id)

      socket =
        user
        |> home_socket(featured: {:movie, regular})
        |> HomeData.toggle_content_favorite("movie", regular.id)

      assert Enum.map(socket.assigns.favorites, & &1.content_id) == [regular.id]
    end
  end

  describe "load/1" do
    test "fills Para Você from the safe catalog when vector recommendations are empty" do
      user = user_fixture()
      provider = global_provider_fixture()

      regular =
        movie_fixture(provider, %{
          name: "Fallback recommendation",
          title: "Fallback recommendation",
          year: Date.utc_today().year,
          stream_icon: "https://example.com/fallback.jpg"
        })

      adult =
        movie_fixture(provider, %{
          name: "Adult fallback recommendation",
          title: "Adult fallback recommendation",
          year: Date.utc_today().year,
          stream_icon: "https://example.com/adult-fallback.jpg"
        })

      adult_category =
        Repo.insert!(%Streamix.Iptv.Category{
          provider_id: provider.id,
          name: "Adult recommendation fallback",
          type: "vod",
          external_id: "adult-recommendation-fallback",
          is_adult: true
        })

      Repo.insert_all("item_categories", [
        %{catalog_item_id: adult.catalog_item_id, category_id: adult_category.id}
      ])

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, current_scope: user_scope_fixture(user)}
        }
        |> HomeData.assign_empty()
        |> HomeData.load()

      assert Enum.map(socket.assigns.recommendations, & &1.id) == [regular.id]
      assert hd(socket.assigns.recommendations).stream_icon == "https://example.com/fallback.jpg"
    end
  end

  defp home_socket(user, attrs) do
    assigns =
      %{
        __changed__: %{},
        current_scope: user_scope_fixture(user),
        featured: nil,
        favorites: [],
        featured_favorite: false,
        movie_favorites_map: MapSet.new(),
        series_favorites_map: MapSet.new()
      }
      |> Map.merge(Map.new(attrs))

    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
