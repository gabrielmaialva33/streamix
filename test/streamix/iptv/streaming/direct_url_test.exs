defmodule Streamix.Iptv.Streaming.DirectUrlTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Streaming.DirectUrl

  @pass "p@ss word/1"

  test "http is upgraded to https; an explicit :80 goes, another port stays" do
    assert {:ok, "https://cdn.example/m/1.mp4?username=u&token=t"} =
             DirectUrl.prepare("http://cdn.example:80/m/1.mp4?username=u&token=t", @pass)

    assert {:ok, "https://cdn.example/m/1.mp4"} =
             DirectUrl.prepare("http://cdn.example/m/1.mp4", @pass)

    assert {:ok, "https://cdn.example:8080/m/1.mp4"} =
             DirectUrl.prepare("http://cdn.example:8080/m/1.mp4", @pass)

    assert {:ok, "https://cdn.example/m/1.mp4"} =
             DirectUrl.prepare("https://cdn.example/m/1.mp4", @pass)
  end

  test "the password is refused in raw, encoded and decoded forms" do
    assert {:error, :credentials_in_url} =
             DirectUrl.prepare("https://cdn.example/movie/u/s3cr3t-Pa55/1.mp4", "s3cr3t-Pa55")

    # A raw password that is not even valid in a URL is refused as unsafe.
    assert {:error, _refused} =
             DirectUrl.prepare("https://cdn.example/u/p@ss word/1/1.mp4", @pass)

    for url <- [
          "https://cdn.example/m/1.mp4?password=#{URI.encode_www_form(@pass)}",
          "https://cdn.example/m/#{URI.encode(@pass)}/1.mp4",
          "https://cdn.example/m/1.mp4?k=p%40ss%20word%2F1"
        ] do
      assert {:error, :credentials_in_url} = DirectUrl.prepare(url, @pass), url
    end
  end

  test "userinfo, other schemes and junk are refused" do
    for url <- [
          "https://user:secret@cdn.example/1.mp4",
          "ftp://cdn.example/1.mp4",
          "javascript:alert(1)",
          "https:///no-host.mp4",
          "not a url"
        ] do
      assert {:error, :unsafe_url} = DirectUrl.prepare(url, @pass), url
    end

    assert {:error, :unsafe_url} = DirectUrl.prepare(nil, @pass)
  end

  test "a provider without a password has nothing to leak" do
    assert {:ok, "https://cdn.example/1.mp4"} = DirectUrl.prepare("http://cdn.example/1.mp4", nil)
    assert {:ok, "https://cdn.example/1.mp4"} = DirectUrl.prepare("http://cdn.example/1.mp4", "")
  end
end
