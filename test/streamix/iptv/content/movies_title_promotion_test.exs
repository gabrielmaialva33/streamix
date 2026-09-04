defmodule Streamix.Iptv.Content.MoviesTitlePromotionTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Iptv.Content.Movies.Enrichment
  alias Streamix.Iptv.TmdbClient

  setup do
    provider = global_provider_fixture(%{provider_type: :gindex})
    %{provider: provider}
  end

  test "parse_movie_response carries the TMDB title under a private key" do
    attrs = TmdbClient.parse_movie_response(%{"id" => 1, "title" => "A Jornada de Vivo"})

    assert attrs[:_tmdb_title] == "A Jornada de Vivo"
    refute Map.has_key?(attrs, :title)
  end

  test "parse_series_response reads TMDB's `name` for the same key" do
    attrs = TmdbClient.parse_series_response(%{"id" => 1, "name" => "Uma Série"})

    assert attrs[:_tmdb_title] == "Uma Série"
  end

  test "fills a blank title from TMDB", %{provider: provider} do
    movie =
      movie_fixture(provider, %{
        title: nil,
        name: "A Jornada de Vivo 2021 1080p NF WEB-DL DDP5 1 Atmos x264-PiA"
      })

    {:ok, updated} = Enrichment.update_movie(movie, %{_tmdb_title: "A Jornada de Vivo"})

    assert updated.title == "A Jornada de Vivo"
  end

  test "never replaces a title the row already has", %{provider: provider} do
    movie = movie_fixture(provider, %{title: "Título do provider"})

    {:ok, updated} = Enrichment.update_movie(movie, %{_tmdb_title: "Título do TMDB"})

    assert updated.title == "Título do provider"
  end

  # The provider outranks TMDB on its own catalog, and `Movies.fetch_info`
  # merges the xtream attrs over the TMDB ones — so an explicit `:title` wins.
  test "yields to an explicit title in the same attrs", %{provider: provider} do
    movie = movie_fixture(provider, %{title: nil})

    {:ok, updated} =
      Enrichment.update_movie(movie, %{title: "Do provider", _tmdb_title: "Do TMDB"})

    assert updated.title == "Do provider"
  end

  test "leaves the title alone when TMDB has none", %{provider: provider} do
    movie = movie_fixture(provider, %{title: nil})

    {:ok, updated} = Enrichment.update_movie(movie, %{_tmdb_title: "   "})

    assert updated.title == nil
  end
end
