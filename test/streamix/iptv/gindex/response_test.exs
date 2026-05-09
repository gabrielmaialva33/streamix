defmodule Streamix.Iptv.Gindex.ResponseTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Gindex.Response

  test "extract_download_link marks GDI download links as inline for browser playback" do
    assert {:ok, url} =
             Response.extract_download_link(
               %{"link" => "/download.aspx?file=abc&expiry=123&mac=sig"},
               "https://gindex.example"
             )

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.path == "/download.aspx"
    assert query["file"] == "abc"
    assert query["expiry"] == "123"
    assert query["mac"] == "sig"
    assert query["inline"] == "true"
  end

  test "extract_download_link preserves existing inline download links" do
    assert {:ok, url} =
             Response.extract_download_link(
               %{"link" => "/download.aspx?file=abc&expiry=123&mac=sig&inline=true"},
               "https://gindex.example"
             )

    assert URI.decode_query(URI.parse(url).query)["inline"] == "true"
  end
end
