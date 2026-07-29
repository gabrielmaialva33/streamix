defmodule StreamixWeb.ManifestController do
  @moduledoc """
  Serves the PWA manifest as release metadata, not as an immutable asset.

  Browsers may keep an installed application's manifest for a long time.
  Revalidation here, paired with keeping the manifest out of the service
  worker precache, lets icon, shortcut and install metadata follow a deploy.
  """

  use StreamixWeb, :controller

  @manifest_path "manifest.json"

  def show(conn, _params) do
    body =
      :streamix
      |> Application.app_dir("priv/static")
      |> Path.join(@manifest_path)
      |> File.read!()

    etag =
      :crypto.hash(:sha256, body)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    etag = ~s("#{etag}")

    conn =
      conn
      |> put_resp_content_type("application/manifest+json")
      |> put_resp_header("cache-control", "no-cache, must-revalidate")
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      send_resp(conn, 200, body)
    end
  end
end
