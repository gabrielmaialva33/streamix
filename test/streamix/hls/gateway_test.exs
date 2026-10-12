defmodule Streamix.Hls.GatewayTest do
  use ExUnit.Case, async: true

  alias Streamix.Hls.Gateway

  @ts <<0x47>> <> :binary.copy(<<0>>, 187) <> <<0x47>> <> :binary.copy(<<0>>, 187)

  test "only allowlisted upstream media types survive" do
    assert Gateway.media_type(%{"content-type" => ["video/MP2T; charset=binary"]}) == "video/mp2t"
    assert Gateway.media_type(%{"content-type" => ["text/html"]}) == "application/octet-stream"

    assert Gateway.media_type(%{"content-type" => ["application/javascript"]}) ==
             "application/octet-stream"

    assert Gateway.media_type(%{}) == "application/octet-stream"
  end

  test "a body that is visibly MPEG-TS is labelled by its content" do
    js = %{"content-type" => ["application/javascript"]}

    assert Gateway.media_type(js, @ts) == "video/mp2t"
    # One sync byte is not enough: the next packet must start with one too.
    assert Gateway.media_type(js, "G" <> :binary.copy("x", 400)) == "application/octet-stream"
    assert Gateway.media_type(%{"content-type" => ["video/mp4"]}, "ftyp") == "video/mp4"
  end

  test "a rewritten playlist names only gateway URLs" do
    body = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:6,\ns.ts\n"
    register = fn refs -> {:ok, Enum.map(refs, fn {_url, kind} -> "id-#{kind}" end)} end

    assert {:ok, rewritten} =
             Gateway.rewrite_playlist(
               body,
               "https://93.184.216.34/v/x.m3u8",
               register,
               &"/r/#{&1}"
             )

    assert String.trim_trailing(rewritten) ==
             "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/r/id-media\"\n#EXTINF:6,\n/r/id-media"
  end

  test "a single byte range is accepted and anything else refused" do
    assert Gateway.valid_range(nil) == :ok
    assert Gateway.valid_range("bytes=0-") == :ok
    assert Gateway.valid_range("bytes=-500") == :ok
    assert Gateway.valid_range("bytes=0-1,4-5") == {:error, :invalid_range}
    assert Gateway.valid_range("items=0-1") == {:error, :invalid_range}
  end
end
