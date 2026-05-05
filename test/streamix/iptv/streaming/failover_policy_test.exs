defmodule Streamix.Iptv.Streaming.FailoverPolicyTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Streaming.FailoverPolicy

  describe "failover_url?/1" do
    test "matches default service-abuse pattern" do
      assert FailoverPolicy.failover_url?("http://provider.com/service-abuse/landing")
      assert FailoverPolicy.failover_url?("http://provider.com/service_abuse/")
      assert FailoverPolicy.failover_url?("https://x/account-suspended.html")
    end

    test "leaves unrelated URLs alone" do
      refute FailoverPolicy.failover_url?("http://provider.com/movie/u/p/123.mp4")
      refute FailoverPolicy.failover_url?(nil)
      refute FailoverPolicy.failover_url?("")
    end
  end

  describe "failover_status?/1" do
    test "rotates on creds-rejected / geo / quota" do
      for status <- [401, 403, 429, 451, 509] do
        assert FailoverPolicy.failover_status?(status), "expected #{status} to rotate"
      end
    end

    test "ignores transient and success statuses" do
      for status <- [200, 206, 301, 404, 500, 502] do
        refute FailoverPolicy.failover_status?(status), "did not expect #{status} to rotate"
      end
    end
  end

  describe "swap_host/2" do
    test "replaces hostname while preserving path/query" do
      assert {:ok, swapped} =
               FailoverPolicy.swap_host(
                 "http://primary.example.com/movie/u/p/123.mp4?token=x",
                 "alt.example.com"
               )

      assert URI.parse(swapped).host == "alt.example.com"
      assert URI.parse(swapped).path == "/movie/u/p/123.mp4"
      assert URI.parse(swapped).query == "token=x"
    end

    test "accepts a full alternate URL with scheme" do
      assert {:ok, swapped} =
               FailoverPolicy.swap_host(
                 "http://primary.example.com:8080/path",
                 "https://alt.example.com:8443"
               )

      uri = URI.parse(swapped)
      assert uri.scheme == "https"
      assert uri.host == "alt.example.com"
      assert uri.port == 8443
    end

    test "rejects malformed inputs" do
      assert :error = FailoverPolicy.swap_host("ftp://x.com/p", "alt.com")
      assert :error = FailoverPolicy.swap_host("http://x.com/p", nil)
    end
  end

  describe "build_url_chain/2" do
    test "returns just the original URL when no alternates" do
      assert FailoverPolicy.build_url_chain("http://x.com/p", []) == ["http://x.com/p"]
    end

    test "swaps each alternate host into the original path" do
      chain =
        FailoverPolicy.build_url_chain(
          "http://primary.com/movie/u/p/123.mp4",
          ["http://primary.com", "http://alt1.com", "http://alt2.com"]
        )

      assert ["http://primary.com/movie/u/p/123.mp4" | rest] = chain
      hosts = Enum.map(rest, &URI.parse(&1).host)
      assert hosts == ["alt1.com", "alt2.com"]
    end

    test "drops alternates whose host equals the original" do
      chain =
        FailoverPolicy.build_url_chain(
          "http://primary.com/path",
          ["http://primary.com", "http://primary.com"]
        )

      assert chain == ["http://primary.com/path"]
    end
  end
end
