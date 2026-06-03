defmodule StreamixWeb.HomeDataTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv
  alias StreamixWeb.HomeData

  describe "toggle_content_favorite/3" do
    test "persists movie favorites from home card previews and refreshes home state" do
      user = user_fixture()
      provider = provider_fixture(user)
      movie = movie_fixture(provider, %{title: "Preview Favorite"})

      socket = home_socket(user, featured: {:movie, movie})

      refute Iptv.favorite?(user.id, "movie", movie.id)

      socket = Data.toggle_content_favorite(socket, "movie", Integer.to_string(movie.id))

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

      socket = Data.toggle_content_favorite(socket, :series, series.id)

      refute Iptv.favorite?(user.id, "series", series.id)
      refute MapSet.member?(socket.assigns.series_favorites_map, series.id)
      refute socket.assigns.featured_favorite
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
