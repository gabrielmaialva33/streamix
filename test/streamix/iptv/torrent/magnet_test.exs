defmodule Streamix.Iptv.Torrent.MagnetTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Torrent.Magnet

  @hash "5B6E178EC1C77D932068BE9BE185BAD19D564C49"

  describe "build/3" do
    test "produces a magnet URI with lowercased hash and default trackers" do
      uri = Magnet.build(@hash, "Poison Candy 2022 1080p")

      assert String.starts_with?(uri, "magnet:?xt=urn:btih:#{String.downcase(@hash)}")
      assert String.contains?(uri, "dn=Poison+Candy+2022+1080p")

      for tracker <- Magnet.default_trackers() do
        assert uri =~ URI.encode_www_form(tracker)
      end
    end

    test "skips dn= when display_name is empty" do
      uri = Magnet.build(@hash)
      refute uri =~ "dn="
      assert uri =~ "xt=urn:btih:"
    end

    test "appends extra trackers without duplicating defaults" do
      extra = ["udp://custom.tracker:1337/announce"]
      uri = Magnet.build(@hash, "name", trackers: extra)

      assert uri =~ URI.encode_www_form(hd(extra))

      # default tracker count should match the constant — duplicate
      # entries between extra + defaults must be deduped.
      tracker_count =
        ~r/[?&]tr=/
        |> Regex.scan(uri)
        |> length()

      assert tracker_count == length(Magnet.default_trackers()) + 1
    end
  end

  describe "info_hash/1" do
    test "extracts and lowercases the hash from any magnet URI" do
      uri = "magnet:?xt=urn:btih:#{@hash}&dn=foo&tr=udp://x"
      assert Magnet.info_hash(uri) == String.downcase(@hash)
    end

    test "returns nil for malformed URIs" do
      assert Magnet.info_hash("magnet:?xt=urn:sha1:nope") == nil
      assert Magnet.info_hash("not a magnet") == nil
    end
  end

  describe "display_name/1" do
    test "URL-decodes the dn= slot" do
      uri = Magnet.build(@hash, "The Matrix 1999")
      assert Magnet.display_name(uri) == "The Matrix 1999"
    end

    test "returns nil when dn= is absent" do
      assert Magnet.display_name(Magnet.build(@hash)) == nil
    end
  end

  describe "trackers/1" do
    test "returns every tr= URL, decoded" do
      uri = Magnet.build(@hash, "x", trackers: ["udp://custom:1234/announce"])
      trackers = Magnet.trackers(uri)

      assert "udp://custom:1234/announce" in trackers
      assert length(trackers) == length(Magnet.default_trackers()) + 1
    end
  end
end
