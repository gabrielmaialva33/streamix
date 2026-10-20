defmodule Streamix.Iptv.GenresTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Category, Genre, Genres, Movie, Series}
  alias Streamix.Iptv.Genres.Vocabulary
  alias Streamix.Iptv.Sync.Metadata

  describe "canonicalize/0" do
    test "promotes the raw rows that already mean a genre and keeps their links" do
      provider = global_provider_fixture()
      drama = raw_genre!("drama")
      show = series_content_fixture(provider)
      link!(show, drama)

      assert {:ok, report} = Genres.canonicalize()
      assert report.genres == length(Vocabulary.all())

      assert %Genre{slug: "drama", name: "Drama", position: position} = Repo.get!(Genre, drama.id)
      assert position == Enum.find(Vocabulary.all(), &(&1.slug == "drama")).position
      assert slugs(show) == ["drama"]
    end

    test "promotes or moves composite, English and accentless names, and drops what is no genre" do
      provider = global_provider_fixture()
      show = series_content_fixture(provider)
      reel = series_content_fixture(provider)

      for name <- ["sci-fi & fantasy", "comédia / drama", "documentary", "familia"] do
        link!(show, raw_genre!(name))
      end

      link!(reel, raw_genre!("histórias da ásia"))
      raw_genre!("rio")

      # "documentary" and "familia" each mean one genre, so they are promoted;
      # the two composites, the reels trope and "rio" are deleted.
      assert {:ok, %{deleted_raw_genres: 4}} = Genres.canonicalize()

      assert slugs(show) ==
               Enum.sort(~w(ficcao-cientifica fantasia comedia drama documentario familia))

      assert slugs(reel) == []
      assert Repo.aggregate(from(g in Genre, where: is_nil(g.slug)), :count) == 0
    end

    test "fills titles without a genre from their categories and clears adult titles" do
      provider = global_provider_fixture()
      tagged = series_content_fixture(provider)
      untagged = series_content_fixture(provider)
      movie = movie_fixture(provider)
      adult = movie_fixture(provider)
      comedy = category!(provider, "series", "Séries | Comédia")
      in_category!(tagged, comedy)
      in_category!(untagged, comedy)
      in_category!(movie, category!(provider, "vod", "▶️ Terror & Suspense"))
      drama = category!(provider, "vod", "Drama")
      in_category!(adult, drama)
      in_category!(adult, category!(provider, "vod", "♠️ Adultos XXXX", is_adult: true))
      link!(tagged, raw_genre!("drama"))
      link!(adult, raw_genre!("romance"))

      assert {:ok, report} = Genres.canonicalize()
      assert report.movies.removed_from_adult == 1

      assert slugs(tagged) == ["drama"]
      assert slugs(untagged) == ["comedia"]
      assert slugs(movie) == ["suspense", "terror"]
      assert slugs(adult) == []
    end

    test "running it again changes nothing" do
      provider = global_provider_fixture()
      show = series_content_fixture(provider)
      link!(show, raw_genre!("action & adventure"))

      assert {:ok, _} = Genres.canonicalize()
      long_ago = ~U[2020-01-01 00:00:00Z]
      Repo.update_all(Genre, set: [updated_at: long_ago])
      genres = Repo.all(from g in Genre, order_by: g.id)

      assert {:ok, report} = Genres.canonicalize()
      assert report.moved_links == 0 and report.deleted_raw_genres == 0
      assert report.series.filled_from_categories == 0
      assert Repo.all(from g in Genre, order_by: g.id) == genres
      assert slugs(show) == ["acao", "aventura"]
    end
  end

  describe "sync" do
    test "maps provider genre strings onto canonical genres and never creates one" do
      provider = global_provider_fixture()
      show = series_content_fixture(provider)
      reel = series_content_fixture(provider)

      sync_series(provider, [
        %{"series_id" => show.series_id, "genre" => "Sci-Fi & Fantasy, Drama"},
        %{"series_id" => reel.series_id, "genre" => "Histórias da Ásia"}
      ])

      assert slugs(show) == ["drama", "fantasia", "ficcao-cientifica"]
      assert slugs(reel) == []
      assert Repo.aggregate(Genre, :count) == length(Vocabulary.all())
    end

    test "a genre string replaces the category fallback, and a changed string replaces the old" do
      provider = global_provider_fixture()
      show = series_content_fixture(provider)
      in_category!(show, category!(provider, "series", "Comédia"))

      sync_series(provider, [%{"series_id" => show.series_id}])
      assert slugs(show) == ["comedia"]

      sync_series(provider, [%{"series_id" => show.series_id, "genre" => "Drama"}])
      assert slugs(show) == ["drama"]

      sync_series(provider, [%{"series_id" => show.series_id, "genre" => "Mistério"}])
      assert slugs(show) == ["misterio"]
    end

    test "movies follow their categories, and lose their genres when they turn adult" do
      provider = global_provider_fixture()
      movie = movie_fixture(provider)
      action = category!(provider, "vod", "FILMES | Ação e Aventura")
      in_category!(movie, action)

      sync_movies(provider, [movie])
      assert slugs(movie) == ["acao", "aventura"]

      Repo.delete_all(
        from ic in "item_categories", where: ic.catalog_item_id == ^movie.catalog_item_id
      )

      in_category!(movie, category!(provider, "vod", "Terror"))
      sync_movies(provider, [movie])
      assert slugs(movie) == ["terror"]

      in_category!(movie, category!(provider, "vod", "FILMES | Adultos +18", is_adult: true))
      sync_movies(provider, [movie])
      assert slugs(movie) == []
    end

    test "an adult title gets no genre from its string or its other categories" do
      provider = global_provider_fixture()
      show = series_content_fixture(provider)
      in_category!(show, category!(provider, "series", "Drama"))
      in_category!(show, category!(provider, "series", "Hentai", is_adult: true))

      sync_series(provider, [%{"series_id" => show.series_id, "genre" => "Romance"}])

      assert slugs(show) == []
    end

    test "only touches the synced provider" do
      provider = global_provider_fixture()
      other = global_provider_fixture()
      mine = movie_fixture(provider)
      theirs = movie_fixture(other)
      in_category!(mine, category!(provider, "vod", "Drama"))
      in_category!(theirs, category!(other, "vod", "Drama"))
      ids = Genres.canonical_ids()
      Repo.insert_all("movie_genres", [%{movie_id: theirs.id, genre_id: ids["terror"]}])

      sync_movies(provider, [mine])

      assert slugs(mine) == ["drama"]
      assert slugs(theirs) == ["terror"]
    end
  end

  defp sync_series(provider, streams) do
    assert :ok =
             Metadata.sync_genres_and_credits(
               streams,
               provider.id,
               Series,
               "series_genres",
               "series_id",
               credits_table: "series_credits",
               stream_id_key: "series_id"
             )
  end

  defp sync_movies(provider, movies) do
    assert :ok =
             Metadata.sync_genres_and_credits(
               Enum.map(movies, &%{"stream_id" => &1.stream_id}),
               provider.id,
               Movie,
               "movie_genres",
               "movie_id",
               credits_table: "movie_credits"
             )
  end

  defp raw_genre!(name), do: Repo.insert!(%Genre{name: name})

  defp link!(%Series{id: id}, genre),
    do: Repo.insert_all("series_genres", [%{series_id: id, genre_id: genre.id}])

  defp link!(%Movie{id: id}, genre),
    do: Repo.insert_all("movie_genres", [%{movie_id: id, genre_id: genre.id}])

  defp category!(provider, type, name, opts \\ []) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      name: name,
      type: type,
      is_adult: Keyword.get(opts, :is_adult, false),
      external_id: Integer.to_string(System.unique_integer([:positive]))
    })
    |> Repo.insert!()
  end

  defp in_category!(item, category) do
    Repo.insert_all("item_categories", [
      %{catalog_item_id: item.catalog_item_id, category_id: category.id}
    ])
  end

  defp slugs(%Movie{id: id}), do: slugs("movie_genres", :movie_id, id)
  defp slugs(%Series{id: id}), do: slugs("series_genres", :series_id, id)

  defp slugs(table, fk, id) do
    from(link in table,
      join: g in Genre,
      on: g.id == link.genre_id,
      where: field(link, ^fk) == ^id,
      order_by: g.slug,
      select: g.slug
    )
    |> Repo.all()
  end
end
