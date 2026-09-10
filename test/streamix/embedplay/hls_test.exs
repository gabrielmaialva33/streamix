defmodule Streamix.Embedplay.HLSTest do
  use ExUnit.Case, async: true

  alias Streamix.Embedplay.HLS

  test "discovers variant, audio, iframe, initialization, key and segment references" do
    body = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="pt, BR",URI="../audio.m3u8?sig=a%2Bb"
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,URI="iframe.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"
    video/index.m3u8?sig=one&part=2
    #EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"
    #EXT-X-KEY:METHOD=AES-128,URI="//93.184.216.34/key?k=%2F"
    #EXTINF:6,
    ?segment=1
    #EXT-X-ENDLIST
    """

    assert {:ok, nodes} = HLS.parse(body, "https://93.184.216.34/root/master.m3u8?old=1")
    references = for {:resource, url, kind} <- nodes, do: {url, kind}

    assert references == [
             {"https://93.184.216.34/audio.m3u8?sig=a%2Bb", :playlist},
             {"https://93.184.216.34/root/iframe.m3u8", :playlist},
             {"https://93.184.216.34/root/video/index.m3u8?sig=one&part=2", :playlist},
             {"https://93.184.216.34/root/init.mp4", :media},
             {"https://93.184.216.34/key?k=%2F", :media},
             {"https://93.184.216.34/root/master.m3u8?segment=1", :media}
           ]

    assert Enum.any?(nodes, &(is_binary(&1) and String.contains?(&1, "NAME=\"pt, BR\"")))
  end

  test "fails closed for unsupported variables, steering, unsafe schemes and malformed attributes" do
    for line <- [
          "#EXT-X-DEFINE:NAME=\"host\",VALUE=\"https://example.com\"",
          "#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://example.com/steer.json\"",
          "#EXT-X-KEY:METHOD=AES-128,URI=unquoted",
          "#EXT-X-KEY:METHOD=AES-128,URI=\"https://example.com/key\",URI=https://example.com/leak",
          "data:application/octet-stream;base64,AAAA",
          "https://name:password@example.com/key"
        ] do
      assert {:error, _} = HLS.parse("#EXTM3U\n" <> line, "https://93.184.216.34/root.m3u8")
    end
  end
end
