defmodule Streamix.HelpersTest do
  use ExUnit.Case, async: true

  alias Streamix.Helpers

  describe "genre_names/1" do
    test "returns nil for nil, empty list, or unloaded association" do
      assert Helpers.genre_names(nil) == nil
      assert Helpers.genre_names([]) == nil
      assert Helpers.genre_names(%Ecto.Association.NotLoaded{}) == nil
    end

    test "orders genres by position (nil last) then name" do
      genres = [
        %{name: "Raw Beta", position: nil},
        %{name: "Drama", position: 7},
        %{name: "Aventura", position: 2},
        %{name: "Ação", position: 1},
        %{name: "Raw Alpha", position: nil}
      ]

      assert Helpers.genre_names(genres) == "Ação, Aventura, Drama, Raw Alpha, Raw Beta"
    end
  end

  describe "genre_refs/1" do
    test "returns empty list for nil, empty list, or unloaded association" do
      assert Helpers.genre_refs(nil) == []
      assert Helpers.genre_refs([]) == []
      assert Helpers.genre_refs(%Ecto.Association.NotLoaded{}) == []
    end

    test "emits only canonical genres with a slug, in position then name order" do
      genres = [
        %{slug: nil, name: "raw-without-slug", position: nil},
        %{slug: "", name: "empty-slug", position: 1},
        %{slug: "drama", name: "Drama", position: 7},
        %{slug: "aventura", name: "Aventura", position: 2},
        %{slug: "acao", name: "Ação", position: 1}
      ]

      assert Helpers.genre_refs(genres) == [
               %{slug: "acao", name: "Ação"},
               %{slug: "aventura", name: "Aventura"},
               %{slug: "drama", name: "Drama"}
             ]
    end
  end
end
