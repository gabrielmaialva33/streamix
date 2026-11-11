defmodule Streamix.ProgrammingTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Programming
  alias Streamix.Programming.{Lineup, Station, StationServer}

  describe "sync_lineup/0" do
    test "creates the shipped stations, refreshes them and retires the rest" do
      retired =
        Repo.insert!(%Station{slug: "antigo", name: "Antigo", query: "x", active: true})

      assert :ok = Programming.sync_lineup()
      slugs = Enum.map(Lineup.stations(), & &1.slug)

      for slug <- slugs, do: assert(%Station{active: true} = Programming.get_station(slug))
      refute Repo.reload!(retired).active

      # Running it again changes nothing.
      assert :ok = Programming.sync_lineup()
      assert Repo.aggregate(Station, :count) == length(slugs) + 1
    end
  end

  describe "rebuild_programs/1" do
    setup :stub_discovery

    test "builds a looping program from public movies with a feature runtime", %{movies: movies} do
      station = station!("terror-teste", "terror anos 80")
      now = ~U[2026-11-11 06:30:00Z]

      assert Programming.rebuild_programs(now: now) == ["terror-teste"]

      station = Repo.reload!(station)
      assert station.program_started_at == now
      assert length(station.program) == 5

      ids = Enum.map(station.program, & &1["content_id"])
      assert Enum.sort(ids) == Enum.sort(Enum.map(movies.feature, & &1.id))
      refute movies.short.id in ids

      assert %{"type" => "movie", "duration" => 5_400, "title" => "Filme " <> _} =
               hd(station.program)

      # Same station, same day: same order.
      assert Programming.rebuild_programs(now: now) == ["terror-teste"]
      assert Enum.map(Repo.reload!(station).program, & &1["content_id"]) == ids
    end

    test "only_empty leaves running programs alone" do
      station = station!("cheio", "terror")

      station
      |> Station.program_changeset(
        [%{"movie_id" => 1, "duration" => 60}],
        ~U[2026-11-10 00:00:00Z]
      )
      |> Repo.update!()

      assert Programming.rebuild_programs(only_empty: true) == []
    end
  end

  describe "rebuild_programs/1 for series stations" do
    test "plays random episodes of each series, runtimes filled from the series" do
      owner = user_fixture()

      global =
        provider_fixture(owner, %{visibility: "global", is_system: true, provider_type: "xtream"})

      _empty_copy = series_content_fixture(global, %{title: "Sitcom A", tmdb_id: "9001"})
      sitcom = series_with_episodes!(global, "Sitcom A", "9001", List.duplicate(1_320, 6))
      cartoon = series_with_episodes!(global, "Desenho B", "9002", [nil, nil, 30])

      station =
        %Station{}
        |> Station.changeset(%{
          slug: "maratona-teste",
          name: "Maratona",
          query: "Maratona",
          kind: "series",
          series_tmdb_ids: ["9001", "9002"]
        })
        |> Repo.insert!()

      assert Programming.rebuild_programs() == ["maratona-teste"]
      program = Repo.reload!(station).program

      assert length(program) == 9
      assert Enum.all?(program, &(&1["type"] == "episode"))

      by_series = Enum.group_by(program, & &1["title"])
      assert length(by_series["Sitcom A"]) == 6
      assert Enum.all?(by_series["Sitcom A"], &(&1["duration"] == 1_320))
      assert Enum.all?(by_series["Sitcom A"], &(&1["poster"] == sitcom.cover))
      # No usable runtime at all (30 s is not an episode): the 25-min default.
      assert Enum.all?(by_series["Desenho B"], &(&1["duration"] == 1_500))
      assert Enum.any?(by_series["Desenho B"], &(&1["subtitle"] == "T1:E1 · Episódio 1"))
      assert cartoon.id
    end

    test "a series station needs its series" do
      changeset =
        Station.changeset(%Station{}, %{slug: "vazia", name: "Vazia", query: "x", kind: "series"})

      assert %{series_tmdb_ids: ["lists no series"]} = errors_on(changeset)
    end
  end

  describe "now_playing/1 and station servers" do
    test "answers from the stored program and from an on-air server alike" do
      station = on_air_station!("no-ar")

      assert {:ok, %{station: %Station{slug: "no-ar"}, slot: from_store}} =
               Programming.now_playing("no-ar")

      start_supervised!({StationServer, station.slug})
      assert {:ok, %{slot: from_server}} = Programming.now_playing("no-ar")
      assert from_server.item == from_store.item

      assert Programming.now_playing("nao-existe") == {:error, :not_found}
      assert [%{station: %{slug: "no-ar"}}] = Programming.list_now_playing()
    end

    test "a server tells subscribers when the program changes" do
      station = on_air_station!("muda")
      start_supervised!({StationServer, station.slug})
      :ok = Programming.subscribe("muda")

      station
      |> Station.program_changeset([%{"movie_id" => 77, "duration" => 3_600}], DateTime.utc_now())
      |> Repo.update!()

      StationServer.reload("muda")
      assert_receive {:station_slot, "muda", %{item: %{"movie_id" => 77}, offset: 0}}
    end

    test "a server announces the next item when the current one ends" do
      # Starts 1 s before the first item ends; the server wakes at least 1 s out.
      station =
        station!("rapido", "x")
        |> Station.program_changeset(
          [%{"movie_id" => 1, "duration" => 2}, %{"movie_id" => 2, "duration" => 60}],
          DateTime.add(DateTime.utc_now(), -1, :second)
        )
        |> Repo.update!()

      :ok = Programming.subscribe(station.slug)
      start_supervised!({StationServer, station.slug})
      assert_receive {:station_slot, "rapido", %{item: %{"movie_id" => 2}}}, 4_000
    end

    test "ensure_on_air starts one server per listed station" do
      on_air_station!("um")
      on_air_station!("dois")
      assert :ok = Programming.ensure_on_air()

      for slug <- ["um", "dois"] do
        assert [{pid, _}] = Registry.lookup(Streamix.Programming.Registry, slug)

        # terminate_child, not a kill: a killed :transient server is restarted
        # and would query the database after this test's sandbox is gone.
        on_exit(fn ->
          DynamicSupervisor.terminate_child(Streamix.Programming.StationSupervisor, pid)
        end)
      end
    end
  end

  defp series_with_episodes!(provider, title, tmdb_id, runtimes) do
    series =
      series_content_fixture(provider, %{
        title: title,
        tmdb_id: tmdb_id,
        cover: "https://img.test/#{tmdb_id}.jpg"
      })

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "T1", series_id: series.id})
      |> Repo.insert!()

    for {runtime, n} <- Enum.with_index(runtimes, 1) do
      %Episode{}
      |> Episode.changeset(%{
        episode_id: System.unique_integer([:positive]),
        episode_num: n,
        title: "Episódio #{n}",
        container_extension: "mp4",
        season_id: season.id
      })
      |> Ecto.Changeset.put_change(:duration_secs, runtime)
      |> Ecto.Changeset.put_change(
        :catalog_item_id,
        catalog_item_fixture("episode", provider.id).id
      )
      |> Repo.insert!()
    end

    series
  end

  defp station!(slug, query) do
    %Station{}
    |> Station.changeset(%{slug: slug, name: String.capitalize(slug), query: query})
    |> Repo.insert!()
  end

  defp on_air_station!(slug) do
    slug
    |> station!("x")
    |> Station.program_changeset(
      [
        %{"movie_id" => 1, "duration" => 3_600, "title" => "Um"},
        %{"movie_id" => 2, "duration" => 3_600}
      ],
      DateTime.utc_now()
    )
    |> Repo.update!()
  end

  # Discovery answers with every fixture movie; the builder must then keep
  # only public, feature-length ones.
  defp stub_discovery(_context) do
    owner = user_fixture()

    global =
      provider_fixture(owner, %{visibility: "global", is_system: true, provider_type: "xtream"})

    feature =
      for n <- 1..5, do: movie_fixture(global, %{title: "Filme #{n}", duration_secs: 5_400})

    short = movie_fixture(global, %{title: "Curta", duration_secs: 600})
    ids = Enum.map(feature ++ [short], & &1.id)

    saved =
      for key <- [:qdrant, :gemini, :embeddings], do: {key, Application.get_env(:streamix, key)}

    req = Req.default_options()
    Application.put_env(:streamix, :qdrant, enabled: true, url: "http://qdrant.test")
    Application.put_env(:streamix, :gemini, api_key: "programming-test")
    Application.put_env(:streamix, :embeddings, provider: "gemini")
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:streamix, key)
        {key, value} -> Application.put_env(:streamix, key, value)
      end)

      Req.default_options(req)
    end)

    Req.Test.stub(__MODULE__, &discovery_stub(&1, ids))

    %{movies: %{feature: feature, short: short}}
  end

  defp discovery_stub(%{host: "qdrant.test"} = conn, ids) do
    points =
      for {id, n} <- Enum.with_index(ids) do
        %{"id" => id, "score" => 0.9 - n / 100, "payload" => %{"variant_key" => "v#{id}"}}
      end

    Req.Test.json(conn, %{"result" => points})
  end

  defp discovery_stub(conn, _ids), do: Req.Test.json(conn, %{"embedding" => %{"values" => [0.1]}})
end
