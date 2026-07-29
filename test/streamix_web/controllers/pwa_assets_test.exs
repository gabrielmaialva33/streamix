defmodule StreamixWeb.PwaAssetsTest do
  use StreamixWeb.ConnCase, async: true

  test "manifest references valid screenshots and an explicit share encoding", %{conn: conn} do
    manifest =
      conn
      |> get("/manifest.json")
      |> json_response(200)

    assert manifest["share_target"]["enctype"] == "application/x-www-form-urlencoded"
    assert length(manifest["screenshots"]) == 3

    for screenshot <- manifest["screenshots"] do
      assert screenshot["type"] == "image/jpeg"

      response = get(build_conn(), screenshot["src"])
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["image/jpeg"]
      assert byte_size(response.resp_body) > 10_000
    end
  end

  test "offline page is neutral, accessible and has no inline script", %{conn: conn} do
    html =
      conn
      |> get("/offline.html")
      |> html_response(200)

    assert html =~ "Você está offline"
    assert html =~ "precisa de conexão"
    assert html =~ ~s(<form action="/" method="get">)
    refute html =~ "onclick="
  end

  test "service worker is served fresh with a concrete cache version", %{conn: conn} do
    response = get(conn, "/sw.js")

    assert response.status == 200

    assert get_resp_header(response, "cache-control") == [
             "no-cache, no-store, must-revalidate"
           ]

    assert get_resp_header(response, "service-worker-allowed") == ["/"]
    refute response.resp_body =~ "__SW_CACHE_VERSION__"
  end
end
