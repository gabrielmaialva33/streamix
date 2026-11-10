defmodule Streamix.AI.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Streamix.AI.Discovery
  alias Streamix.Catalog

  setup do
    saved =
      for key <- [:qdrant, :gemini, :embeddings], do: {key, Application.get_env(:streamix, key)}

    req = Req.default_options()

    Application.put_env(:streamix, :qdrant, enabled: true, url: "http://qdrant.test")
    Application.put_env(:streamix, :gemini, api_key: "test-key")
    Application.put_env(:streamix, :embeddings, provider: "gemini")
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, value} <- saved do
        if value,
          do: Application.put_env(:streamix, key, value),
          else: Application.delete_env(:streamix, key)
      end

      Req.default_options(req)
    end)
  end

  test "named genres, decades and providers are hard filters" do
    parsed = Catalog.parse_discovery_query("terror anos 80")

    assert Discovery.filter(parsed, [1, 2]) == %{
             must: [
               %{key: "provider_id", match: %{any: [1, 2]}},
               %{key: "genres", match: %{any: ["Terror"]}},
               %{
                 should: [
                   %{key: "year", range: %{gte: 1980, lte: 1989}},
                   %{key: "eras", match: %{any: ["anos-1980"]}}
                 ]
               }
             ]
           }

    # Tags and implied genres never filter: unclassified titles stay findable.
    assert Discovery.filter(Catalog.parse_discovery_query("slasher leve"), nil) == nil
  end

  test "collapses copies, boosts matching tags and ranks best first" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.host do
        "qdrant.test" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(owner, {:qdrant, Jason.decode!(raw)})

          Req.Test.json(conn, %{
            "result" => [
              point(1, 0.80, "tmdb:1", %{"genres" => ["Terror"]}),
              point(2, 0.79, "tmdb:1", %{"genres" => ["Terror"]}),
              point(3, 0.76, "tmdb:3", %{
                "genres" => ["Terror"],
                "subgenres" => ["slasher"],
                "moods" => ["tenso"]
              }),
              point(4, 0.70, "tmdb:4", %{"genres" => ["Drama"]})
            ]
          })

        _gemini ->
          Req.Test.json(conn, %{"embedding" => %{"values" => [0.1, 0.2]}})
      end
    end)

    assert {:ok, %{results: results, parsed: parsed}} =
             Discovery.discover("slasher tenso", :movies, limit: 3, provider_ids: [7])

    assert Enum.map(results, & &1.id) == [3, 1, 4]
    assert hd(results).matched == [:subgenres, :moods]
    assert parsed.implied_genres == ["terror"]

    assert_received {:qdrant, body}
    assert body["filter"] == %{"must" => [%{"key" => "provider_id", "match" => %{"any" => [7]}}]}
    assert body["score_threshold"] == 0.0
    assert body["limit"] >= 120
  end

  test "several collections share one query embedding" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:request, conn.host, conn.request_path})

      case conn.host do
        "qdrant.test" -> Req.Test.json(conn, %{"result" => [point(9, 0.5, "tmdb:9", %{})]})
        _gemini -> Req.Test.json(conn, %{"embedding" => %{"values" => [0.3]}})
      end
    end)

    query = "faroeste #{System.unique_integer([:positive])}"

    assert {:ok, %{results: %{movies: [%{id: 9}], series: [%{id: 9}]}}} =
             Discovery.discover(query, [:movies, :series])

    assert_received {:request, "generativelanguage.googleapis.com", _path}
    refute_received {:request, "generativelanguage.googleapis.com", _path}
    assert_received {:request, "qdrant.test", "/collections/movies/points/search"}
    assert_received {:request, "qdrant.test", "/collections/series/points/search"}
  end

  defp point(id, score, key, payload) do
    %{
      "id" => id,
      "score" => score,
      "payload" => Map.merge(%{"variant_key" => key, "title" => "T#{id}"}, payload)
    }
  end
end
