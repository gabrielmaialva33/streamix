defmodule Streamix.Iptv.Content.TmdbGenresSourcesTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Gindex.TmdbMatcher
  alias Streamix.Iptv.Content.Movies.Enrichment
  alias Streamix.Iptv.Content.SeriesOps.Enrichment, as: SeriesEnrichment
  alias Streamix.Iptv.TmdbClient.Parser
  alias Streamix.Workers.Gindex.BackfillTmdbWorker

  setup do
    previous = Application.get_env(:streamix, :tmdb)
    previous_gindex = Application.get_env(:streamix, :tmdb_gindex)
    previous_options = Req.default_options()
    Application.put_env(:streamix, :tmdb, enabled: true, api_token: "test-token")
    Application.put_env(:streamix, :tmdb_gindex, enabled: true, api_token: "test-token")
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)

    on_exit(fn ->
      restore(:streamix, :tmdb, previous)
      restore(:streamix, :tmdb_gindex, previous_gindex)
      Req.default_options(previous_options)
    end)

    %{provider: global_provider_fixture()}
  end

  test "detail parsers retain empty genres and filter invalid ids" do
    for parser <- [&Parser.parse_movie_response/1, &Parser.parse_series_response/1] do
      assert parser.(%{"id" => 1, "genres" => []})[:tmdb_genre_ids] == []

      assert parser.(%{
               "id" => 1,
               "genres" => [%{"id" => 28}, %{"id" => "18"}, %{"id" => -1}, nil, %{"id" => 28}]
             })[:tmdb_genre_ids] == [28]

      refute Map.has_key?(parser.(%{"id" => 1}), :tmdb_genre_ids)
      refute Map.has_key?(parser.(%{"id" => 1, "genres" => nil}), :tmdb_genre_ids)
    end
  end

  test "movie enrichment propagates fetched genres across providers", %{provider: provider} do
    movie = movie_fixture(provider, %{tmdb_id: "550"})
    copy = movie_fixture(global_provider_fixture(), %{tmdb_id: "550"})

    assert {:ok, updated} = Enrichment.update_movie(movie, %{tmdb_genre_ids: [28], plot: "New"})
    assert updated.tmdb_genre_ids == [28]
    assert Enum.map(updated.genres, & &1.slug) == ["acao"]
    assert Repo.reload!(movie).plot == "New"
    assert Repo.reload!(copy).tmdb_genre_ids == [28]
    assert slugs(movie) == ["acao"]
    assert slugs(copy) == ["acao"]
  end

  test "absent genre attrs preserve earlier ids", %{provider: provider} do
    movie = movie_fixture(provider, %{tmdb_id: "550"})
    assert {:ok, movie} = Enrichment.update_movie(movie, %{tmdb_genre_ids: [18]})
    assert {:ok, _} = Enrichment.update_movie(movie, %{plot: "New"})
    assert Repo.reload!(movie).tmdb_genre_ids == [18]
    assert slugs(movie) == ["drama"]
  end

  test "failed movie update cannot propagate genres", %{provider: provider} do
    movie = movie_fixture(provider, %{tmdb_id: "550"})
    assert {:error, _} = Enrichment.update_movie(movie, %{name: nil, tmdb_genre_ids: [28]})
    assert Repo.reload!(movie).tmdb_genre_ids == nil
    assert slugs(movie) == []
  end

  test "explicit empty movie genres record a completed fetch", %{provider: provider} do
    movie = movie_fixture(provider, %{tmdb_id: "550"})
    assert {:ok, updated} = Enrichment.update_movie(movie, %{tmdb_genre_ids: []})
    assert updated.tmdb_genre_ids == []
    assert Repo.reload!(movie).tmdb_genre_ids == []
  end

  test "genre attrs without a TMDB id return an error without marking the row fetched", %{
    provider: provider
  } do
    for tmdb_id <- [nil, ""] do
      movie = movie_fixture(provider, %{tmdb_id: tmdb_id})
      assert {:error, :missing_tmdb_id} = Enrichment.update_movie(movie, %{tmdb_genre_ids: [28]})
      assert Repo.reload!(movie).tmdb_genre_ids == nil
    end
  end

  test "series enrichment applies already fetched detail genres", %{provider: provider} do
    tmdb_id = to_string(System.system_time(:nanosecond))
    series = series_content_fixture(provider, %{tmdb_id: tmdb_id})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/3/tv/#{tmdb_id}"
      Req.Test.json(conn, %{"id" => tmdb_id, "genres" => [%{"id" => 10_765}]})
    end)

    assert {:ok, updated} = SeriesEnrichment.fetch_info(series)
    assert updated.tmdb_genre_ids == [10_765]
    assert Enum.sort(Enum.map(updated.genres, & &1.slug)) == ["fantasia", "ficcao-cientifica"]
    assert updated.credits == []
    assert slugs(series) == ["fantasia", "ficcao-cientifica"]
    Req.Test.verify!(__MODULE__)
  end

  test "search candidates preserve validated genres and missing versus empty" do
    for {kind, field} <- [{:movie, "title"}, {:series, "name"}],
        {raw, expected} <- [{[28, "18", nil, -1, 28], [28]}, {[], []}, {nil, nil}] do
      title = unique_title()

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"results" => [%{"id" => 550, field => title, "genre_ids" => raw}]})
      end)

      assert {:ok, candidate} = TmdbMatcher.best_match(title, nil, kind)
      assert candidate.genre_ids == expected
    end

    Req.Test.verify!(__MODULE__)
  end

  test "matched movie stores id and propagates search genres", %{provider: provider} do
    title = unique_title()
    movie = movie_fixture(provider, %{name: title, tmdb_id: nil})
    copy = movie_fixture(global_provider_fixture(), %{tmdb_id: "550"})

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "results" => [%{"id" => 550, "title" => title, "genre_ids" => [18]}]
      })
    end)

    assert :ok =
             BackfillTmdbWorker.perform(%Oban.Job{
               args: %{"kind" => "movie", "ids" => [movie.id]}
             })

    assert Repo.reload!(movie).tmdb_id == "550"
    assert Repo.reload!(movie).tmdb_genre_ids == [18]
    assert Repo.reload!(copy).tmdb_genre_ids == [18]
    assert slugs(movie) == ["drama"]
    Req.Test.verify!(__MODULE__)
  end

  test "matched series stores search genres through the series mapping", %{provider: provider} do
    title = unique_title()
    series = series_content_fixture(provider, %{name: title, tmdb_id: nil})

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "results" => [%{"id" => 1399, "name" => title, "genre_ids" => [10_765]}]
      })
    end)

    assert :ok =
             BackfillTmdbWorker.perform(%Oban.Job{
               args: %{"kind" => "series", "ids" => [series.id]}
             })

    assert Repo.reload!(series).tmdb_id == "1399"
    assert Repo.reload!(series).tmdb_genre_ids == [10_765]
    assert slugs(series) == ["fantasia", "ficcao-cientifica"]
    Req.Test.verify!(__MODULE__)
  end

  # Letters only: the release parser reads digit runs as years or episode
  # numbers, which made a numeric suffix change the searched title at random.
  defp unique_title do
    suffix = for _ <- 1..12, into: "", do: <<Enum.random(?a..?z)>>
    "Genrematch #{suffix}"
  end

  defp slugs(item) do
    item
    |> Repo.preload(:genres, force: true)
    |> Map.fetch!(:genres)
    |> Enum.map(& &1.slug)
    |> Enum.sort()
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
