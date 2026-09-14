defmodule Streamix.Iptv.Content.MoviesEnrichmentSourcesTest do
  @moduledoc """
  The nightly sweeps enrich thousands of movies per run, and every one of them
  used to issue a `get_vod_info` against the same Xtream account that serves
  playback — unpaced, because `ProviderRuntime.acquire/3` only admits `:live`
  and `:vod`. These tests pin the opt-out: background callers must reach TMDB
  without touching the panel, while interactive callers keep both legs.

  The panel here is a real HTTP server on loopback that counts its hits, so a
  regression shows up as a request that should not exist rather than as a
  mocked expectation.
  """
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.Movies
  alias Streamix.Workers.{BackfillTmdbAssetsWorker, TmdbDetailsWorker}

  setup do
    previous = Application.get_env(:streamix, :tmdb)
    Application.put_env(:streamix, :tmdb, enabled: false)
    on_exit(fn -> Application.put_env(:streamix, :tmdb, previous) end)

    hits = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.CountingPanel, hits: hits},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    provider = global_provider_fixture(%{provider_type: :xtream, url: "http://127.0.0.1:#{port}"})
    movie = movie_fixture(provider, %{tmdb_id: "550"})

    %{movie: Repo.preload(movie, :provider), hits: hits}
  end

  defp hit_count(hits), do: Agent.get(hits, & &1)

  test "background enrichment reaches TMDB without calling the panel", %{
    movie: movie,
    hits: hits
  } do
    assert {:ok, _updated} = Movies.fetch_info(movie, sources: [:tmdb])

    assert hit_count(hits) == 0,
           "sources: [:tmdb] must not issue get_vod_info — this is the per-item " <>
             "upstream call the nightly sweeps multiply by thousands"
  end

  test "interactive enrichment still consults the panel", %{movie: movie, hits: hits} do
    assert {:ok, _updated} = Movies.fetch_info(movie)

    assert hit_count(hits) == 1,
           "the default must stay unchanged: a detail view is one request by one " <>
             "viewer, and the panel is where container_extension comes from"
  end

  test "an explicit :xtream source opts back in", %{movie: movie, hits: hits} do
    assert {:ok, _updated} = Movies.fetch_info(movie, sources: [:xtream, :tmdb])
    assert hit_count(hits) == 1
  end

  test "skipping the panel preserves the stored TMDB match", %{movie: movie} do
    assert {:ok, updated} = Movies.fetch_info(movie, sources: [:tmdb])
    assert updated.tmdb_id == "550"
  end

  test "dropping :tmdb skips the search that resolves a missing id", %{
    movie: movie,
    hits: hits
  } do
    {:ok, unmatched} = movie |> Ecto.Changeset.change(tmdb_id: nil) |> Repo.update()

    assert {:ok, updated} = Movies.fetch_info(unmatched, sources: [:xtream])

    assert hit_count(hits) == 1, "the panel leg must still run when :xtream is requested"
    assert is_nil(updated.tmdb_id), "no id may appear when :tmdb was not among the sources"
  end

  # The option above is only worth having if the callers that cost thousands of
  # upstream calls per night actually pass it. Asserting on `fetch_info/2`
  # alone would stay green if someone reverted the worker back to `/1`.
  describe "nightly workers" do
    test "TmdbDetailsWorker enriches a movie without calling the panel", %{
      movie: movie,
      hits: hits
    } do
      assert :ok =
               TmdbDetailsWorker.perform(%Oban.Job{
                 args: %{"kind" => "movie", "ids" => [movie.id]}
               })

      assert hit_count(hits) == 0,
             "TmdbDetailsWorker processes up to 3,000 movies a night; each panel " <>
               "call here is one unpaced request against the playback account"
    end

    test "BackfillTmdbAssetsWorker backfills artwork without calling the panel", %{
      movie: movie,
      hits: hits
    } do
      assert :ok =
               BackfillTmdbAssetsWorker.perform(%Oban.Job{
                 args: %{"kind" => "movies", "ids" => [movie.id]}
               })

      assert hit_count(hits) == 0
    end
  end

  defmodule CountingPanel do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      Agent.update(Keyword.fetch!(opts, :hits), &(&1 + 1))

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"info" => %{}}))
    end
  end
end
