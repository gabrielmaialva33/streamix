defmodule Streamix.Iptv.Streaming.SourceUrlTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Streaming.SourceUrl

  # Synthetic test fixture — never reuse a real production secret in tests
  # checked into a public repo. Rotate any leaked secret immediately.
  @secret "0000000000000000000000000000000000000000000000000000000000000000"
  @base "https://source.mahina.cloud"
  @upstream "http://example.com/test.mp4"

  setup do
    original_secret = Application.get_env(:streamix, :source_proxy_shared_secret)
    original_base = Application.get_env(:streamix, :stream_proxy_url)

    Application.put_env(:streamix, :source_proxy_shared_secret, @secret)
    Application.put_env(:streamix, :stream_proxy_url, @base)

    on_exit(fn ->
      Application.put_env(:streamix, :source_proxy_shared_secret, original_secret)
      Application.put_env(:streamix, :stream_proxy_url, original_base)
    end)

    :ok
  end

  describe "build/2" do
    test "returns a signed source URL" do
      assert {:ok, url} = SourceUrl.build(@upstream)
      assert String.starts_with?(url, "#{@base}/proxy?")

      query = URI.parse(url).query |> URI.decode_query()
      assert query["url"] == @upstream
      assert {exp_int, ""} = Integer.parse(query["exp"])
      assert exp_int > System.system_time(:second)
      assert is_binary(query["sig"]) and byte_size(query["sig"]) > 0
    end

    test "honors custom TTL" do
      now = System.system_time(:second)
      {:ok, url} = SourceUrl.build(@upstream, ttl: 30)
      query = URI.parse(url).query |> URI.decode_query()
      {exp_int, ""} = Integer.parse(query["exp"])
      assert exp_int >= now + 29 and exp_int <= now + 31
    end

    test "errors when secret missing" do
      Application.delete_env(:streamix, :source_proxy_shared_secret)
      assert {:error, :no_secret} = SourceUrl.build(@upstream)
    end

    test "signature matches the nginx secure_link MD5 formula" do
      now = System.system_time(:second)
      exp = now + 300
      {:ok, url} = SourceUrl.build(@upstream, exp_at: exp)

      query = URI.parse(url).query |> URI.decode_query()

      # Mirror the nginx-side computation: md5_bin("$exp:$url $secret")
      # base64url-encoded, no padding.
      expected =
        :crypto.hash(:md5, "#{exp}:#{@upstream} #{@secret}")
        |> Base.url_encode64(padding: false)

      assert query["sig"] == expected
    end
  end

  describe "verify/1" do
    test "accepts a freshly built signature" do
      {:ok, url} = SourceUrl.build(@upstream)
      query = URI.parse(url).query |> URI.decode_query()
      assert :ok = SourceUrl.verify(query)
    end

    test "rejects bad signature" do
      {:ok, url} = SourceUrl.build(@upstream)
      query = URI.parse(url).query |> URI.decode_query() |> Map.put("sig", "tampered")
      assert {:error, :bad_sig} = SourceUrl.verify(query)
    end

    test "rejects expired" do
      past = System.system_time(:second) - 10
      {:ok, url} = SourceUrl.build(@upstream, exp_at: past)
      query = URI.parse(url).query |> URI.decode_query()
      assert {:error, :expired} = SourceUrl.verify(query)
    end

    test "missing fields" do
      assert {:error, :missing} = SourceUrl.verify(%{})
    end
  end
end
