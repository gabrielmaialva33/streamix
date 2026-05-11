defmodule StreamixWeb.TvDownloadController do
  use StreamixWeb, :controller

  @release_tag "v1.0.000"
  @github_release_base "https://github.com/gabrielmaialva33/streamix-tv/releases/download"

  def apk(conn, _params) do
    redirect_to_asset(conn, "Streamix-#{@release_tag}.apk")
  end

  def wgt(conn, _params) do
    redirect_to_asset(conn, "Streamix-#{@release_tag}.wgt")
  end

  defp redirect_to_asset(conn, filename) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> redirect(external: "#{@github_release_base}/#{@release_tag}/#{filename}")
  end
end
