defmodule StreamixWeb.TvDownloadControllerTest do
  use StreamixWeb.ConnCase, async: true

  test "GET /tv/apk redirects to the current APK release asset", %{conn: conn} do
    conn = get(conn, ~p"/tv/apk")

    assert redirected_to(conn, 302) ==
             "https://github.com/gabrielmaialva33/streamix-tv/releases/download/v1.0.000/Streamix-v1.0.000.apk"

    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end

  test "GET /tv/wgt redirects to the current WGT release asset", %{conn: conn} do
    conn = get(conn, ~p"/tv/wgt")

    assert redirected_to(conn, 302) ==
             "https://github.com/gabrielmaialva33/streamix-tv/releases/download/v1.0.000/Streamix-v1.0.000.wgt"

    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end
end
