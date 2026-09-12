defmodule Streamix.Iptv.Content.MoviesInfoPreservationTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Iptv.Content.Movies.Enrichment
  alias Streamix.Iptv.{Movie, Movies}

  setup do
    previous = Application.get_env(:streamix, :tmdb)
    Application.put_env(:streamix, :tmdb, enabled: false)
    on_exit(fn -> Application.put_env(:streamix, :tmdb, previous) end)

    payload = start_supervised!({Agent, fn -> %{} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.ApiPlug, payload: payload},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    provider = global_provider_fixture(%{provider_type: :xtream, url: "http://127.0.0.1:#{port}"})
    movie = movie_fixture(provider, %{tmdb_id: "550", imdb_id: "tt0137523"})
    %{movie: Repo.preload(movie, :provider), payload: payload}
  end

  test "zero panel IDs and Kinopoisk URLs cannot erase matched IDs", %{
    movie: movie,
    payload: payload
  } do
    for missing_id <- [0, "0", nil, ""] do
      Agent.update(payload, fn _ ->
        %{"tmdb_id" => missing_id, "kinopoisk_url" => "https://www.kinopoisk.ru/film/361/"}
      end)

      attrs = Enrichment.fetch_xtream_attrs(movie)
      refute Map.has_key?(attrs, :tmdb_id)
      refute Map.has_key?(attrs, :imdb_id)
      assert {:ok, updated} = Movies.fetch_info(movie)
      assert updated.tmdb_id == "550"
      assert updated.imdb_id == "tt0137523"
    end
  end

  test "stored ID wins over a different valid panel ID, including persisted merge", %{
    movie: movie,
    payload: payload
  } do
    Agent.update(payload, fn _ -> %{"tmdb_id" => 680} end)
    assert {:ok, updated} = Movies.fetch_info(movie)
    assert updated.tmdb_id == "550"
    assert Repo.get!(Movie, movie.id).tmdb_id == "550"
  end

  test "TMDB details are fetched for the stored match, not the panel ID", %{
    movie: movie,
    payload: payload
  } do
    Application.put_env(:streamix, :tmdb, enabled: true, api_token: "test-only-cached-response")

    for {id, plot} <- [{"550", "Correct matched synopsis"}, {"680", "Wrong panel synopsis"}] do
      key = Cache.tmdb_movie_key(id)
      assert :ok = Cache.set(key, {:ok, %{"id" => String.to_integer(id), "overview" => plot}})
      on_exit(fn -> Cache.delete(key) end)
    end

    Agent.update(payload, fn _ -> %{"tmdb_id" => 680} end)
    assert {:ok, updated} = Movies.fetch_info(movie)
    assert updated.plot == "Correct matched synopsis"
    assert updated.tmdb_id == "550"
  end

  test "a valid panel ID fills a missing or previously poisoned stored ID", %{
    movie: movie,
    payload: payload
  } do
    Agent.update(payload, fn _ -> %{"tmdb_id" => 680} end)

    for old_id <- [nil, "", "0"] do
      Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [tmdb_id: old_id])
      assert {:ok, updated} = Movies.fetch_info(Repo.get!(Movie, movie.id))
      assert updated.tmdb_id == "680"
    end
  end

  test "only canonical IMDb identifiers enter the parsed attrs", %{movie: movie, payload: payload} do
    for key <- ["imdb_id", "kinopoisk_url"],
        value <- [
          "tt123456",
          "tt0137523",
          "tt123456789",
          "tt12345",
          "tt1234567890",
          "tt0137523\n",
          "https://example.com",
          nil
        ] do
      Agent.update(payload, fn _ -> %{key => value} end)
      expected = if value in ["tt123456", "tt0137523", "tt123456789"], do: value, else: nil
      assert Enrichment.fetch_xtream_attrs(movie)[:imdb_id] == expected
    end
  end

  defmodule ApiPlug do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      info = Agent.get(Keyword.fetch!(opts, :payload), & &1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"info" => info}))
    end
  end
end
