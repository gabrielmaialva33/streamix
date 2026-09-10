defmodule Streamix.Embedplay.CatalogClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Embedplay.CatalogClient

  setup do
    original = Application.get_env(:streamix, :embedplay_catalog_request_options)

    Application.put_env(:streamix, :embedplay_catalog_request_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if original do
        Application.put_env(:streamix, :embedplay_catalog_request_options, original)
      else
        Application.delete_env(:streamix, :embedplay_catalog_request_options)
      end
    end)
  end

  test "accepts only the movie inventory envelope from the fixed source" do
    entries = [%{"tmdb_id" => "603", "imdb_id" => "tt0133093"}]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "embedplayapi.top"
      assert conn.request_path == "/api/all-ids"
      assert conn.query_string == "type=movie"
      Req.Test.json(conn, %{status: "success", results: %{movies: entries}})
    end)

    assert {:ok, ^entries} = CatalogClient.movies()
  end

  test "rejects empty or malformed inventory instead of requesting catalog deletion" do
    for body <- [
          %{status: "success", results: %{movies: []}},
          %{status: "error", results: %{movies: []}},
          %{status: "success", results: %{series: [%{tmdb_id: 1}]}}
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))
      assert {:error, reason} = CatalogClient.movies()
      assert reason in [:empty_catalog, :invalid_catalog]
    end
  end

  test "does not follow redirects or expose upstream errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://example.invalid/private")
      |> Plug.Conn.send_resp(302, "untrusted body")
    end)

    assert {:error, :catalog_unavailable} = CatalogClient.movies()
  end
end
