defmodule Streamix.TestSupport.TorrentScraperStub do
  @moduledoc """
  Fixture pages and a URL-routed `Req.Test` stub for the BR torrent
  scrapers.

  The fixtures under `test/support/fixtures/torrent_sources/` are trimmed
  captures of the real sites (taken 2026-10-12): repeated cards/articles and
  heavy sidebars removed, markup, attributes and nesting untouched.

  `route/1` installs a stub for `Streamix.Torrent.Sources.ScraperHttp`
  (wired in `config/test.exs`) that answers by full URL and reports every
  request to the calling test process as `{:scraper_request, url, headers}`.
  Unrouted URLs answer 404.
  """

  @fixtures Path.expand("fixtures/torrent_sources", __DIR__)

  @type response ::
          String.t()
          | {pos_integer(), String.t()}
          | {pos_integer(), [{String.t(), String.t()}], String.t()}

  @doc "Reads a fixture page by file name."
  @spec html(String.t()) :: String.t()
  def html(name), do: File.read!(Path.join(@fixtures, name))

  @doc "Routes absolute URLs to responses; a bare string is a 200 HTML page."
  @spec route(%{String.t() => response()}) :: :ok
  def route(routes) when is_map(routes) do
    test_pid = self()

    Req.Test.stub(Streamix.Torrent.Sources.ScraperHttp, fn conn ->
      url = url(conn)
      send(test_pid, {:scraper_request, url, conn.req_headers})
      respond(conn, Map.get(routes, url, {404, "<html><body>not found</body></html>"}))
    end)

    :ok
  end

  @doc "Every URL requested so far, in order (drains the mailbox)."
  @spec requested_urls() :: [String.t()]
  def requested_urls, do: drain([])

  @doc "The Cloudflare managed-challenge response comando.la serves."
  @spec cloudflare_challenge() :: response()
  def cloudflare_challenge do
    {403, [{"cf-mitigated", "challenge"}, {"server", "cloudflare"}],
     html("cloudflare_challenge.html")}
  end

  defp respond(conn, body) when is_binary(body), do: respond(conn, {200, [], body})
  defp respond(conn, {status, body}), do: respond(conn, {status, [], body})

  defp respond(conn, {status, headers, body}) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(status, body)
  end

  defp url(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "#{conn.scheme}://#{conn.host}#{conn.request_path}#{query}"
  end

  defp drain(acc) do
    receive do
      {:scraper_request, url, _headers} -> drain([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
