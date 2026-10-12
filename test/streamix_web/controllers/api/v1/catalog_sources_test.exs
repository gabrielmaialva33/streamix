defmodule StreamixWeb.Api.V1.CatalogSourcesTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Repo

  # Runtime health is keyed by provider id and every test creates fresh
  # providers, so no global reset is needed to keep tests independent.
  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    :ok
  end

  describe "GET /api/v1/catalog/movies/:id/sources" do
    setup do
      global = global_provider_fixture(%{name: "Alpha Global"})
      bravo = public_provider!("Bravo")
      charlie = public_provider!("Charlie")

      current =
        movie_fixture(global, %{
          name: "Shared Feature",
          title: "Shared Feature",
          tmdb_id: "777",
          container_extension: "mp4",
          plot: "A feature shared by several providers.",
          content_rating: "14"
        })

      bravo_movie =
        movie_fixture(bravo, %{
          name: "Shared Feature 4K Dublado",
          title: "Shared Feature",
          tmdb_id: "777",
          container_extension: "mkv"
        })

      charlie_movie =
        movie_fixture(charlie, %{
          name: "Shared Feature HDR Legendado",
          title: "Shared Feature",
          tmdb_id: "777",
          container_extension: "mp4"
        })

      # Bravo answers, the requested copy's provider rejects the account and
      # Charlie has no evidence yet: that runtime evidence decides the order.
      ProviderRuntime.record_success(bravo.id, :control, 40)
      ProviderRuntime.record_failure(global.id, :control, :authentication_failed)

      %{
        global: global,
        bravo: bravo,
        charlie: charlie,
        current: current,
        bravo_movie: bravo_movie,
        charlie_movie: charlie_movie
      }
    end

    test "ranks the copies, flags the recommended and requested ones and labels them", ctx do
      response =
        ctx.conn
        |> get(~p"/api/v1/catalog/movies/#{ctx.current.id}/sources")
        |> json_response(200)

      assert response == %{
               "data" => [
                 %{
                   "id" => ctx.bravo_movie.id,
                   "provider_id" => ctx.bravo.id,
                   "provider_name" => "Bravo",
                   "provider_status" => "healthy",
                   "title" => "Shared Feature 4K Dublado",
                   "container_extension" => "mkv",
                   "badges" => ["MKV", "4K", "DUB"],
                   "recommended" => true,
                   "current" => false
                 },
                 %{
                   "id" => ctx.charlie_movie.id,
                   "provider_id" => ctx.charlie.id,
                   "provider_name" => "Charlie",
                   "provider_status" => "unknown",
                   "title" => "Shared Feature HDR Legendado",
                   "container_extension" => "mp4",
                   "badges" => ["MP4", "HDR", "LEG"],
                   "recommended" => false,
                   "current" => false
                 },
                 %{
                   "id" => ctx.current.id,
                   "provider_id" => ctx.global.id,
                   "provider_name" => "Alpha Global",
                   "provider_status" => "unhealthy",
                   "title" => "Shared Feature",
                   "container_extension" => "mp4",
                   "badges" => ["MP4"],
                   "recommended" => false,
                   "current" => true
                 }
               ]
             }
    end

    test "matches the web player's failover chain for the same title", ctx do
      ids =
        ctx.conn
        |> get(~p"/api/v1/catalog/movies/#{ctx.current.id}/sources")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      viewer = user_fixture()
      movie = Streamix.Playback.get_playable_movie(viewer.id, ctx.current.id)

      expected =
        "movie"
        |> StreamixWeb.PlayerHelpers.failover_sources(movie, viewer.id)
        |> Enum.map(& &1.id)

      assert ids == expected
    end

    test "omits copies the stream endpoint would refuse", ctx do
      owner = user_fixture()
      private = provider_fixture(owner, %{name: "Private"})
      inactive = "Inactive" |> public_provider!() |> update_provider!(is_active: false)
      degraded = "Degraded" |> public_provider!() |> update_provider!(health_status: :degraded)
      torrent = global_provider_fixture(%{name: "Torrent", provider_type: :torrent})

      refused =
        for provider <- [private, inactive, degraded, torrent] do
          movie_fixture(provider, %{name: "Shared Feature", tmdb_id: "777"}).id
        end

      ids =
        ctx.conn
        |> get(~p"/api/v1/catalog/movies/#{ctx.current.id}/sources")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert Enum.sort(ids) ==
               Enum.sort([ctx.current.id, ctx.bravo_movie.id, ctx.charlie_movie.id])

      assert Enum.all?(refused, &(&1 not in ids))
    end

    test "badges are the ones the movie detail page shows for the same copies", ctx do
      sources =
        ctx.conn
        |> get(~p"/api/v1/catalog/movies/#{ctx.current.id}/sources")
        |> json_response(200)
        |> Map.fetch!("data")

      {:ok, _view, html} =
        build_conn()
        |> log_in_user(user_fixture())
        |> live(~p"/browse/movies/#{ctx.current.id}")

      document = LazyHTML.from_document(html)

      for source <- sources do
        page_badges =
          document
          |> LazyHTML.query("#movie-source-#{source["id"]} [data-source-badge]")
          |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

        assert page_badges == source["badges"]
        assert page_badges != []
      end
    end

    test "keeps the requested copy from a health-degraded provider and reports it", ctx do
      degraded = "Degraded" |> public_provider!() |> update_provider!(health_status: :degraded)

      requested =
        movie_fixture(degraded, %{name: "Shared Feature", title: "Shared Feature", tmdb_id: "777"})

      data =
        ctx.conn
        |> get(~p"/api/v1/catalog/movies/#{requested.id}/sources")
        |> json_response(200)
        |> Map.fetch!("data")

      assert [current] = Enum.filter(data, & &1["current"])
      assert current["id"] == requested.id
      assert current["provider_status"] == "unhealthy"

      assert Enum.map(data, & &1["id"]) |> Enum.sort() ==
               Enum.sort([requested.id, ctx.current.id, ctx.bravo_movie.id, ctx.charlie_movie.id])

      assert [%{"id" => recommended_id}] = Enum.filter(data, & &1["recommended"])
      assert recommended_id == hd(data)["id"]
    end
  end

  describe "GET /api/v1/catalog/movies/:id/sources edge cases" do
    test "a title without other copies lists only itself", %{conn: conn} do
      movie = movie_fixture(global_provider_fixture(), %{name: "Lonely Feature"})

      assert [
               %{
                 "id" => id,
                 "recommended" => true,
                 "current" => true
               }
             ] =
               conn
               |> get(~p"/api/v1/catalog/movies/#{movie.id}/sources")
               |> json_response(200)
               |> Map.fetch!("data")

      assert id == movie.id
    end

    test "a torrent-only title has no source the TV can play", %{conn: conn} do
      torrent = global_provider_fixture(%{name: "Torrent", provider_type: :torrent})
      movie = movie_fixture(torrent, %{name: "Swarm Only", tmdb_id: "778"})

      assert conn
             |> get(~p"/api/v1/catalog/movies/#{movie.id}/sources")
             |> json_response(200) == %{"data" => []}
    end

    test "404s like the movie detail for unknown, private and disabled ids", %{conn: conn} do
      owner = user_fixture()
      private_movie = movie_fixture(provider_fixture(owner))

      disabled_movie =
        "Disabled"
        |> public_provider!()
        |> update_provider!(is_active: false)
        |> movie_fixture()

      for id <- [999_999_999, private_movie.id, disabled_movie.id] do
        assert conn |> get(~p"/api/v1/catalog/movies/#{id}") |> json_response(404)

        assert conn
               |> get(~p"/api/v1/catalog/movies/#{id}/sources")
               |> json_response(404) == %{
                 "error" => %{"code" => "content_not_found", "message" => "Movie not found"}
               }
      end
    end

    test "rejects malformed ids", %{conn: conn} do
      assert conn
             |> get(~p"/api/v1/catalog/movies/not-a-number/sources")
             |> json_response(400) == %{
               "error" => %{
                 "code" => "invalid_parameter",
                 "message" => "Invalid value for parameter id"
               }
             }
    end
  end

  describe "GET /api/v1/catalog/episodes/:id/sources" do
    test "lists the same season and episode number in equivalent series", %{conn: conn} do
      global = global_provider_fixture(%{name: "Alpha Global"})
      bravo = public_provider!("Bravo")
      other_season = public_provider!("Other Season")
      owner = user_fixture()
      private = provider_fixture(owner, %{name: "Private"})

      current = series_with_episode!(global, 1, 2, "S01E02")
      alternative = series_with_episode!(bravo, 1, 2, "S01E02 Dublado", "mkv")
      _other_season = series_with_episode!(other_season, 2, 2, "S02E02")
      private_episode = series_with_episode!(private, 1, 2, "S01E02")

      ProviderRuntime.record_success(bravo.id, :control, 40)

      response =
        conn
        |> get(~p"/api/v1/catalog/episodes/#{current.id}/sources")
        |> json_response(200)

      assert response == %{
               "data" => [
                 %{
                   "id" => alternative.id,
                   "provider_id" => bravo.id,
                   "provider_name" => "Bravo",
                   "provider_status" => "healthy",
                   "title" => "S01E02 Dublado",
                   "container_extension" => "mkv",
                   "badges" => ["MKV", "DUB"],
                   "recommended" => true,
                   "current" => false
                 },
                 %{
                   "id" => current.id,
                   "provider_id" => global.id,
                   "provider_name" => "Alpha Global",
                   "provider_status" => "unknown",
                   "title" => "S01E02",
                   "container_extension" => "mp4",
                   "badges" => ["MP4"],
                   "recommended" => false,
                   "current" => true
                 }
               ]
             }

      refute private_episode.id in Enum.map(response["data"], & &1["id"])
    end

    test "404s like the episode detail for unknown and private ids", %{conn: conn} do
      owner = user_fixture()
      private_episode = series_with_episode!(provider_fixture(owner), 1, 1, "Private")

      for id <- [999_999_999, private_episode.id] do
        assert conn |> get(~p"/api/v1/catalog/episodes/#{id}") |> json_response(404)

        assert conn
               |> get(~p"/api/v1/catalog/episodes/#{id}/sources")
               |> json_response(404) == %{
                 "error" => %{"code" => "content_not_found", "message" => "Episode not found"}
               }
      end
    end
  end

  # Each public provider gets its own owner so per-user provider limits never
  # interfere with the setup.
  defp public_provider!(name) do
    provider_fixture(user_fixture(), %{name: name, visibility: :public})
  end

  defp update_provider!(provider, changes) do
    provider
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp series_with_episode!(provider, season_number, episode_num, title, extension \\ "mp4") do
    series = series_content_fixture(provider, %{name: "Shared Show", tmdb_id: "888"})

    season =
      %Season{}
      |> Season.changeset(%{
        series_id: series.id,
        season_number: season_number,
        name: "Season #{season_number}"
      })
      |> Repo.insert!()

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: episode_num,
      title: title,
      container_extension: extension,
      season_id: season.id,
      catalog_item_id: catalog_item_fixture("episode", provider.id).id
    })
    |> Repo.insert!()
  end
end
