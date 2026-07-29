defmodule StreamixWeb.PwaAssetsTest do
  use StreamixWeb.ConnCase, async: true

  test "manifest references valid screenshots and an explicit share encoding", %{conn: conn} do
    response = get(conn, "/manifest.json")
    manifest = json_response(response, 200)

    assert get_resp_header(response, "content-type") == [
             "application/manifest+json; charset=utf-8"
           ]

    assert get_resp_header(response, "cache-control") == ["no-cache, must-revalidate"]
    assert [_etag] = get_resp_header(response, "etag")

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

  test "manifest revalidates instead of using the immutable static cache", %{conn: conn} do
    first = get(conn, "/manifest.json")
    [etag] = get_resp_header(first, "etag")

    second =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get("/manifest.json")

    assert second.status == 304
    assert second.resp_body == ""
    assert get_resp_header(second, "cache-control") == ["no-cache, must-revalidate"]
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

  test "player decoders are included in static compression" do
    assert ".wasm" in Application.fetch_env!(:phoenix, :gzippable_exts)
  end
end
