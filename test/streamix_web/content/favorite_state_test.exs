defmodule StreamixWeb.Content.FavoriteStateTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv
  alias StreamixWeb.Content.FavoriteState

  test "toggle/4 returns database status and apply_map/4 mirrors it in LiveView state" do
    user = user_fixture()
    provider = provider_fixture(user)
    movie = movie_fixture(provider)
    socket = %{assigns: %{favorites_map: MapSet.new()}}

    assert {:ok, :added} = FavoriteState.toggle(user.id, "movie", movie.id)
    assert Iptv.is_favorite?(user.id, "movie", movie.id)

    socket = FavoriteState.apply_map(socket, :favorites_map, movie.id, :added)
    assert MapSet.member?(socket.assigns.favorites_map, movie.id)

    assert {:ok, :removed} = FavoriteState.toggle(user.id, "movie", movie.id)
    refute Iptv.is_favorite?(user.id, "movie", movie.id)

    socket = FavoriteState.apply_map(socket, :favorites_map, movie.id, :removed)
    refute MapSet.member?(socket.assigns.favorites_map, movie.id)
  end

  test "preserve_boolean/2 keeps the visible state when toggle fails" do
    assert FavoriteState.preserve_boolean(true, {:error, :unauthorized})
    refute FavoriteState.preserve_boolean(false, {:error, :unauthorized})
  end
end
