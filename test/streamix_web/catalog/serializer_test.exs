defmodule StreamixWeb.Catalog.SerializerTest do
  use Streamix.DataCase, async: true

  alias StreamixWeb.Catalog.Serializer

  describe "genre and genres serialization" do
    test "emits both genre string and canonical genres array in stable position order" do
      provider = %{id: 1, name: "Global", provider_type: :xtream}

      genres = [
        %{slug: nil, name: "Unmapped", position: nil},
        %{slug: "drama", name: "Drama", position: 7},
        %{slug: "acao", name: "Ação", position: 1}
      ]

      movie = %{
        id: 10,
        name: "Matrix",
        title: "The Matrix",
        year: 1999,
        rating: Decimal.new("8.7"),
        genres: genres,
        plot: "Plot",
        credits: [],
        duration_secs: 8160,
        content_rating: "14",
        tagline: nil,
        stream_icon: "https://img.example.test/poster.jpg",
        youtube_trailer: nil,
        provider: provider
      }

      series = %{
        id: 20,
        name: "Dark",
        title: "Dark",
        year: 2017,
        rating: Decimal.new("8.8"),
        genres: genres,
        plot: "Plot",
        credits: [],
        cover: "https://img.example.test/cover.jpg",
        seasons: [],
        provider: provider
      }

      expected_refs = [
        %{slug: "acao", name: "Ação"},
        %{slug: "drama", name: "Drama"}
      ]

      for payload <- [
            Serializer.serialize_movie(movie),
            Serializer.serialize_movie_detail(movie),
            Serializer.serialize_featured({:movie, movie}),
            Serializer.serialize_series(series),
            Serializer.serialize_series_detail(series),
            Serializer.serialize_featured({:series, series})
          ] do
        assert payload.genre == "Ação, Drama, Unmapped"
        assert payload.genres == expected_refs
      end
    end
  end
end
