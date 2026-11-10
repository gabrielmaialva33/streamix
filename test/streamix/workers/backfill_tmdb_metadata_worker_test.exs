defmodule Streamix.Workers.BackfillTmdbMetadataWorkerTest do
  use Streamix.DataCase, async: false

  import Ecto.Query
  import Streamix.IptvFixtures

  alias Streamix.Workers.BackfillTmdbMetadataWorker

  setup do
    tmdb = Application.get_env(:streamix, :tmdb)
    config = Application.get_env(:streamix, BackfillTmdbMetadataWorker)
    req = Req.default_options()

    Application.put_env(:streamix, :tmdb, enabled: true, api_token: "test-token")
    Application.put_env(:streamix, BackfillTmdbMetadataWorker, limit: 2_000, delay_ms: 0)
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)

    on_exit(fn ->
      restore(:tmdb, tmdb)
      restore(BackfillTmdbMetadataWorker, config)
      Req.default_options(req)
    end)

    %{provider: global_provider_fixture()}
  end

  test "selects distinct pending ids per kind, caps each kind, and updates every copy",
       %{provider: provider} do
    Application.put_env(:streamix, BackfillTmdbMetadataWorker, limit: 1, delay_ms: 0)
    id = tmdb_id()
    later_id = id <> "9"
    movie = movie_fixture(provider, %{tmdb_id: id})
    copy = movie_fixture(global_provider_fixture(), %{tmdb_id: id})
    fetched_copy = movie_fixture(provider, %{tmdb_id: id}) |> fetched!([28])
    series = series_content_fixture(provider, %{tmdb_id: id})
    later_movie = movie_fixture(provider, %{tmdb_id: later_id})
    later_series = series_content_fixture(provider, %{tmdb_id: later_id})
    movie_fixture(provider, %{tmdb_id: nil})
    movie_fixture(provider, %{tmdb_id: ""})
    fetched = movie_fixture(provider, %{tmdb_id: tmdb_id()}) |> fetched!([])
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:requested, conn.request_path})
      # Only keywords and credits appended: no videos or images.
      assert conn.query_string == "append_to_response=keywords,credits&language=pt-BR"
      Req.Test.json(conn, %{"id" => String.to_integer(id), "genres" => [%{"id" => 18}]})
    end)

    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
    assert_received {:requested, "/3/movie/" <> ^id}
    assert_received {:requested, "/3/tv/" <> ^id}
    refute_received {:requested, _}

    for row <- [movie, copy, fetched_copy, series] do
      assert Repo.reload!(row).tmdb_genre_ids == [18]
    end

    assert Repo.reload!(fetched).tmdb_genre_ids == []
    assert Repo.reload!(later_movie).tmdb_genre_ids == nil
    assert Repo.reload!(later_series).tmdb_genre_ids == nil
  end

  test "404 records an empty answer on every copy and does not fetch it again",
       %{provider: provider} do
    id = tmdb_id()
    movie = movie_fixture(provider, %{tmdb_id: id})
    copy = movie_fixture(global_provider_fixture(), %{tmdb_id: id})

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 404, "missing"))
    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
    assert Repo.reload!(movie).tmdb_genre_ids == []
    assert Repo.reload!(copy).tmdb_genre_ids == []
    assert Repo.reload!(movie).tmdb_keyword_ids == []

    Req.Test.stub(__MODULE__, fn _ -> flunk("404 was fetched again") end)
    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
  end

  test "a rate limit stops the whole run without marking the failed id", %{provider: provider} do
    id = tmdb_id()
    failed = movie_fixture(provider, %{tmdb_id: id})
    later = movie_fixture(provider, %{tmdb_id: id <> "9"})
    series = series_content_fixture(provider, %{tmdb_id: id})
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:requested, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    assert {:error, :rate_limited} = BackfillTmdbMetadataWorker.perform(%Oban.Job{})

    # The client retries a 429 three times before giving up.
    for _ <- 1..4, do: assert_received({:requested, "/3/movie/" <> ^id})
    refute_received {:requested, _}
    for row <- [failed, later, series], do: assert(Repo.reload!(row).tmdb_genre_ids == nil)
  end

  test "a failing title is skipped, stays pending, and the run goes on", %{provider: provider} do
    id = tmdb_id()
    later_id = id <> "9"
    failed = movie_fixture(provider, %{tmdb_id: id})
    later = movie_fixture(provider, %{tmdb_id: later_id})
    no_genres = series_content_fixture(provider, %{tmdb_id: id})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/3/movie/" <> ^later_id ->
          Req.Test.json(conn, %{"id" => 1, "genres" => [%{"id" => 27}]})

        "/3/movie/" <> _ ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        "/3/tv/" <> _ ->
          Req.Test.json(conn, %{"id" => 1})
      end
    end)

    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
    assert Repo.reload!(failed).tmdb_genre_ids == nil
    assert Repo.reload!(later).tmdb_genre_ids == [27]
    assert Repo.reload!(no_genres).tmdb_genre_ids == nil
  end

  test "stores keywords and credits on every copy; adult copies get no credits",
       %{provider: provider} do
    id = tmdb_id()
    movie = movie_fixture(provider, %{tmdb_id: id})
    copy = movie_fixture(global_provider_fixture(), %{tmdb_id: id})
    series = series_content_fixture(provider, %{tmdb_id: id})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/3/movie/" <> _ ->
          Req.Test.json(conn, %{
            "id" => 1,
            "genres" => [%{"id" => 878}],
            "keywords" => %{
              "keywords" => [%{"id" => 4379, "name" => "time travel"}, %{"id" => 0}]
            },
            "credits" => %{
              "cast" => [
                %{"name" => "Second Billed", "order" => 1},
                %{"name" => " Lead Actor ", "order" => 0}
              ],
              "crew" => [
                %{"name" => "Some Director", "job" => "Director", "department" => "Directing"},
                %{"name" => "Some Writer", "job" => "Screenplay", "department" => "Writing"},
                %{"name" => "Some Editor", "job" => "Editor", "department" => "Editing"}
              ]
            }
          })

        "/3/tv/" <> _ ->
          Req.Test.json(conn, %{
            "id" => 1,
            "genres" => [%{"id" => 18}],
            "created_by" => [%{"name" => "Show Creator"}],
            "keywords" => %{"results" => [%{"id" => 9, "name" => "anime"}]},
            "credits" => %{"cast" => [%{"name" => "Series Lead", "order" => 0}]}
          })
      end
    end)

    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})

    for row <- [movie, copy], do: assert(Repo.reload!(row).tmdb_keyword_ids == [4379])
    assert Repo.reload!(series).tmdb_keyword_ids == [9]

    assert Streamix.Catalog.tmdb_keyword_names([4379, 9]) == %{
             4379 => "time travel",
             9 => "anime"
           }

    assert credits("movie_credits", "movie_id", movie.id) == [
             {"cast", 0, "lead actor"},
             {"cast", 1, "second billed"},
             {"director", 0, "some director"},
             {"writer", 0, "some writer"}
           ]

    assert credits("movie_credits", "movie_id", copy.id) ==
             credits("movie_credits", "movie_id", movie.id)

    assert credits("series_credits", "series_id", series.id) == [
             {"cast", 0, "series lead"},
             {"writer", 0, "show creator"}
           ]

    # A second run finds nothing pending and adds nothing twice.
    Req.Test.stub(__MODULE__, fn _ -> flunk("fetched again") end)
    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
  end

  test "a title with genres already fetched is still pending for keywords",
       %{provider: provider} do
    id = tmdb_id()

    movie =
      provider
      |> movie_fixture(%{tmdb_id: id})
      |> Ecto.Changeset.change(tmdb_genre_ids: [18])
      |> Repo.update!()

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => 1,
        "genres" => [%{"id" => 18}],
        "keywords" => %{"keywords" => [%{"id" => 818, "name" => "based on novel or book"}]}
      })
    end)

    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{})
    assert Repo.reload!(movie).tmdb_keyword_ids == [818]
  end

  test "a limit arg overrides the configured one", %{provider: provider} do
    Application.put_env(:streamix, BackfillTmdbMetadataWorker, limit: 1, delay_ms: 0)
    first = movie_fixture(provider, %{tmdb_id: tmdb_id()})
    second = movie_fixture(provider, %{tmdb_id: tmdb_id()})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"id" => 1, "genres" => []})
    end)

    assert :ok = BackfillTmdbMetadataWorker.perform(%Oban.Job{args: %{"limit" => 5}})
    for row <- [first, second], do: assert(Repo.reload!(row).tmdb_keyword_ids == [])
  end

  test "job is unique across active states and uses the details queue" do
    changeset = BackfillTmdbMetadataWorker.new(%{})
    assert Ecto.Changeset.get_field(changeset, :queue) == "tmdb_details"
    unique = Ecto.Changeset.get_field(changeset, :unique)
    assert unique.period == :infinity
    assert :executing in unique.states
    assert :retryable in unique.states
  end

  defp tmdb_id, do: Integer.to_string(System.system_time(:nanosecond))

  defp fetched!(row, ids),
    do: row |> Ecto.Changeset.change(tmdb_genre_ids: ids, tmdb_keyword_ids: []) |> Repo.update!()

  defp credits(table, fk, id) do
    Repo.all(
      from(c in table,
        join: p in "people",
        on: p.id == c.person_id,
        where: field(c, ^String.to_existing_atom(fk)) == ^id,
        order_by: [c.role, c.position],
        select: {c.role, c.position, p.name}
      )
    )
  end

  defp restore(key, nil), do: Application.delete_env(:streamix, key)
  defp restore(key, value), do: Application.put_env(:streamix, key, value)
end
