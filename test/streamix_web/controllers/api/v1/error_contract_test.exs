defmodule StreamixWeb.Api.V1.ErrorContractTest do
  use StreamixWeb.ConnCase, async: true

  alias StreamixWeb.Api.V1.{GindexTracksController, RecommendationsController, SearchController}

  test "invalid GIndex track params use the stable error envelope", %{conn: conn} do
    conn = GindexTracksController.show(conn, %{"type" => "movie", "id" => "not-an-id"})

    assert json_response(conn, 400) == %{
             "error" => %{
               "code" => "invalid_id",
               "message" => "Invalid content id"
             }
           }
  end

  test "invalid semantic search params use distinct machine-readable codes", %{conn: conn} do
    invalid_collection =
      SearchController.similar(conn, %{"collection" => "episodes", "id" => "1"})

    assert get_in(json_response(invalid_collection, 400), ["error", "code"]) ==
             "invalid_collection"

    invalid_id =
      SearchController.similar(conn, %{"collection" => "movies", "id" => "not-an-id"})

    assert get_in(json_response(invalid_id, 400), ["error", "code"]) == "invalid_id"
  end

  test "recommendations reject internal and unknown Qdrant collections", %{conn: conn} do
    for collection <- ["user_profiles", "episodes", "anything"] do
      response = RecommendationsController.index(conn, %{"type" => collection})

      assert get_in(json_response(response, 400), ["error", "code"]) ==
               "invalid_content_type"
    end
  end

  test "API source cannot regress to scalar errors or serialize raw reasons" do
    api_files =
      Path.wildcard("lib/streamix_web/controllers/api/v1/*.ex") ++
        [
          "lib/streamix_web/plugs/api_key_auth.ex",
          "lib/streamix_web/plugs/bearer_auth.ex",
          "lib/streamix_web/plugs/rate_limit.ex"
        ]

    offenders =
      Enum.flat_map(api_files, fn path ->
        source = File.read!(path)

        violations =
          []
          |> maybe_add_violation(source =~ ~r/error:\s*"[^"]+"/, "scalar error")
          |> maybe_add_violation(
            source =~ ~r/(?:reason|message):\s*inspect\(reason\)/,
            "serialized raw reason"
          )

        Enum.map(violations, &{path, &1})
      end)

    assert offenders == []
  end

  defp maybe_add_violation(violations, true, violation), do: [violation | violations]
  defp maybe_add_violation(violations, false, _violation), do: violations
end
