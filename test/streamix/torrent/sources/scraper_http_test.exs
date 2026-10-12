defmodule Streamix.Torrent.Sources.ScraperHttpTest do
  use ExUnit.Case, async: true

  alias Streamix.TestSupport.TorrentScraperStub, as: Stub
  alias Streamix.Torrent.Sources.ScraperHttp

  describe "get/2" do
    test "identifies itself honestly as Streamix" do
      Stub.route(%{"https://comando1.com/" => "<html><body>ok</body></html>"})

      assert {:ok, "<html><body>ok</body></html>"} = ScraperHttp.get("https://comando1.com/")
      assert_received {:scraper_request, "https://comando1.com/", headers}

      user_agent = headers |> List.keyfind("user-agent", 0) |> elem(1)
      assert user_agent == "Mozilla/5.0 (compatible; Streamix/1.0; +https://streamix.mahina.fun)"
      refute user_agent =~ "Chrome"
      refute user_agent =~ "Windows"
    end

    test "reports a Cloudflare managed challenge as blocked, not as content" do
      Stub.route(%{"https://comando.la/" => Stub.cloudflare_challenge()})

      assert {:error, {:blocked, %{url: "https://comando.la/", status: 403, reason: :challenge}}} =
               ScraperHttp.get("https://comando.la/")
    end

    test "reports a challenge interstitial served with 200 as blocked" do
      Stub.route(%{"https://mirror.example/" => Stub.html("cloudflare_challenge.html")})

      assert {:error, {:blocked, %{status: 200, reason: :challenge}}} =
               ScraperHttp.get("https://mirror.example/")
    end

    test "a plain 403 is blocked/forbidden" do
      Stub.route(%{"https://mirror.example/" => {403, "Forbidden"}})

      assert {:error, {:blocked, %{status: 403, reason: :forbidden}}} =
               ScraperHttp.get("https://mirror.example/")
    end

    test "does not mistake Cloudflare's injected script path on a normal page for a challenge" do
      page =
        ~s(<html><body><article>post</article><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></body></html>)

      Stub.route(%{"https://comandotorrents.to/" => page})
      assert {:ok, ^page} = ScraperHttp.get("https://comandotorrents.to/")
    end

    test "429 comes back as rate_limited with the Retry-After delay and is not retried" do
      Stub.route(%{"https://mirror.example/" => {429, [{"retry-after", "30"}], "slow down"}})

      assert {:error, {:rate_limited, %{status: 429, retry_after_ms: 30_000}}} =
               ScraperHttp.get("https://mirror.example/")

      assert Stub.requested_urls() == ["https://mirror.example/"]
    end

    test "404 and other statuses are distinct errors" do
      Stub.route(%{
        "https://mirror.example/gone" => {404, "nope"},
        "https://mirror.example/x" => {500, "boom"}
      })

      assert {:error, {:not_found, %{status: 404}}} =
               ScraperHttp.get("https://mirror.example/gone")

      assert {:error, {:http_error, %{status: 500}}} = ScraperHttp.get("https://mirror.example/x")
    end

    test "spaces consecutive requests to the same host by min_interval_ms" do
      host = "pace-#{System.unique_integer([:positive])}.example"
      Stub.route(%{"https://#{host}/a" => "a", "https://#{host}/b" => "b"})

      started = System.monotonic_time(:millisecond)
      assert {:ok, "a"} = ScraperHttp.get("https://#{host}/a", min_interval_ms: 60)
      assert {:ok, "b"} = ScraperHttp.get("https://#{host}/b", min_interval_ms: 60)

      assert System.monotonic_time(:millisecond) - started >= 60
    end
  end

  describe "challenge?/2" do
    test "recognises the cf-mitigated header" do
      assert ScraperHttp.challenge?(%{"cf-mitigated" => ["challenge"]}, "")
      refute ScraperHttp.challenge?(%{"server" => ["cloudflare"]}, "<html>content</html>")
    end
  end
end
