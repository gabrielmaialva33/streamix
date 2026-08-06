defmodule StreamixWeb.Api.V1.OpenApiContractTest do
  use StreamixWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions, only: [assert_operation_response: 2]
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Episode, MovieCredit, Person, Season}
  alias Streamix.Repo

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    :ok
  end

  test "publishes a navigable, credential-free catalog contract", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi.json") |> json_response(200)

    assert spec["openapi"] =~ ~r/^3\.0\./
    assert spec["info"]["title"] == "Streamix Catalog API"
    assert map_size(spec["paths"]) == 19
    assert spec["components"]["securitySchemes"]["ApiKeyAuth"]["name"] == "X-API-Key"

    operations = Enum.map(spec["paths"], fn {_path, path_item} -> path_item["get"] end)
    operation_ids = Enum.map(operations, & &1["operationId"])

    assert length(Enum.uniq(operation_ids)) == 19
    assert Enum.all?(operations, &Map.has_key?(&1["responses"], "429"))

    assert Enum.all?(operations, fn operation ->
             operation["parameters"] in [nil, []] or Map.has_key?(operation["responses"], "400")
           end)

    provider_schema = spec["components"]["schemas"]["CatalogProvider"]
    provider_fields = Map.keys(provider_schema["properties"])

    assert Enum.sort(provider_fields) ==
             Enum.sort(["id", "name", "type", "content_types", "catalog_counts"])

    refute Enum.any?(provider_fields, &(&1 in ["url", "username", "password"]))

    docs_conn = get(build_conn(), ~p"/api/v1/docs")
    assert html_response(docs_conn, 200) =~ "/api/v1/openapi.json"
  end

  test "successful catalog responses conform to their declared schemas" do
    provider = global_provider_fixture()
    movie_provider = global_provider_fixture(%{provider_type: :torrent})
    movie = contract_movie!(movie_provider)
    series = series_content_fixture(provider, %{name: "Contract Series", tmdb_id: "200"})
    episode = contract_episode!(provider, series)
    channel = channel_fixture(provider, %{name: "Contract Channel"})

    requests = [
      {"/api/v1/catalog/providers", "catalog.providers.list"},
      {"/api/v1/catalog/movies", "catalog.movies.list"},
      {"/api/v1/catalog/series", "catalog.series.list"},
      {"/api/v1/catalog/channels", "catalog.channels.list"},
      {"/api/v1/catalog/categories", "catalog.categories.list"},
      {"/api/v1/catalog/featured", "catalog.featured"},
      {"/api/v1/catalog/search?q=Contract", "catalog.search"},
      {"/api/v1/catalog/suggest?q=Contract", "catalog.suggest"},
      {"/api/v1/catalog/home?limit=5", "catalog.home"},
      {"/api/v1/catalog/trending?limit=5", "catalog.trending"},
      {"/api/v1/catalog/recent?limit=5", "catalog.recent"},
      {"/api/v1/catalog/top-rated?limit=5", "catalog.topRated"},
      {"/api/v1/catalog/movies/#{movie.id}", "catalog.movies.get"},
      {"/api/v1/catalog/series/#{series.id}", "catalog.series.get"},
      {"/api/v1/catalog/episodes/#{episode.id}", "catalog.episodes.get"},
      {"/api/v1/catalog/channels/#{channel.id}", "catalog.channels.get"},
      {"/api/v1/catalog/movies/#{movie.id}/stream", "catalog.movies.stream"},
      {"/api/v1/catalog/episodes/#{episode.id}/stream", "catalog.episodes.stream"},
      {"/api/v1/catalog/channels/#{channel.id}/stream", "catalog.channels.stream"}
    ]

    Enum.each(requests, fn {path, operation_id} ->
      build_conn()
      |> get(path)
      |> assert_status(200)
      |> assert_operation_response(operation_id)
    end)
  end

  test "documented error responses conform to the stable error envelope", %{conn: conn} do
    conn
    |> get(~p"/api/v1/catalog/movies?provider_type=m3u")
    |> assert_status(400)
    |> assert_operation_response("catalog.movies.list")

    build_conn()
    |> get(~p"/api/v1/catalog/movies/not-a-number")
    |> assert_status(400)
    |> assert_operation_response("catalog.movies.get")

    build_conn()
    |> get(~p"/api/v1/catalog/movies/999999999")
    |> assert_status(404)
    |> assert_operation_response("catalog.movies.get")
  end

  test "authentication failures also satisfy every catalog operation contract" do
    Application.put_env(:streamix, :api_keys, ["contract-test-key"])

    build_conn()
    |> get(~p"/api/v1/catalog/providers")
    |> assert_status(401)
    |> assert_operation_response("catalog.providers.list")
  end

  defp assert_status(conn, expected) do
    assert conn.status == expected
    conn
  end

  defp contract_movie!(provider) do
    movie =
      movie_fixture(provider, %{
        name: "Contract Movie",
        title: "Contract Movie",
        plot: "Contract plot",
        tmdb_id: "100",
        content_rating: "PG-13"
      })

    for {name, role} <- [{"Contract Actor", "cast"}, {"Contract Director", "director"}] do
      person =
        %Person{}
        |> Person.changeset(%{name: "#{name} #{System.unique_integer([:positive])}"})
        |> Repo.insert!()

      %MovieCredit{}
      |> MovieCredit.changeset(%{movie_id: movie.id, person_id: person.id, role: role})
      |> Repo.insert!()
    end

    movie
  end

  defp contract_episode!(provider, series) do
    season =
      %Season{}
      |> Season.changeset(%{series_id: series.id, season_number: 1, name: "Season 1"})
      |> Repo.insert!()

    catalog_item = catalog_item_fixture("episode", provider.id)

    %Episode{}
    |> Episode.changeset(%{
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "Contract Episode",
      plot: "Contract episode plot",
      container_extension: "mp4",
      tmdb_enriched: true,
      season_id: season.id,
      catalog_item_id: catalog_item.id
    })
    |> Repo.insert!()
  end
end
