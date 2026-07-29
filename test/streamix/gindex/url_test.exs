defmodule Streamix.Gindex.UrlTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Url

  test "encodes a question mark that belongs to a folder name" do
    assert Url.join(
             "https://gindex.example",
             "/1:/Séries/Afinal, o Que Querem as Mulheres? (2010)/"
           ) ==
             "https://gindex.example/1:/S%C3%A9ries/Afinal,%20o%20Que%20Querem%20as%20Mulheres%3F%20(2010)/"
  end

  test "preserves a real query string on generated download links" do
    assert Url.join_link(
             "https://gindex.example/",
             "/download.aspx?file=abc%2Fdef&expiry=123&mac=sig"
           ) ==
             "https://gindex.example/download.aspx?file=abc%2Fdef&expiry=123&mac=sig"
  end

  test "does not prefix absolute generated links" do
    assert Url.join_link(
             "https://gindex.example",
             "https://download.example/file.mp4?token=abc"
           ) ==
             "https://download.example/file.mp4?token=abc"
  end
end
