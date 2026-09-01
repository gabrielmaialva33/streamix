defmodule StreamixWeb.Helpers.ResizeUrlTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Helpers.ResizeUrl

  describe "flatten/3" do
    test "returns prefixed keys for each allowed width" do
      # Real URLs carry TMDB-style path segments — exercising one here
      # proves we URL-encode the full string (including the `/t/p/...`
      # path) so query-string parsing at the server stays unambiguous.
      url = "https://tmdb.mahina.fun/t/p/w780/foo bar.jpg"
      out = ResizeUrl.flatten("poster", url, [240, 480, 720])

      assert Map.keys(out) |> Enum.sort() == ["poster_w240", "poster_w480", "poster_w720"]
      assert out["poster_w240"] =~ "/api/v1/catalog/images/resize?"
      assert out["poster_w240"] =~ "w=240"
      # `URI.encode_www_form/1` encodes space as `+` and `/` as %2F — the
      # important thing is that raw `/` doesn't leak through.
      refute String.contains?(out["poster_w720"], "/foo bar")
    end

    test "returns an empty map for nil/empty urls" do
      assert ResizeUrl.flatten("poster", nil, [480]) == %{}
      assert ResizeUrl.flatten("poster", "", [480]) == %{}
    end
  end

  describe "variants/2" do
    test "keeps the raw url alongside the sized variants" do
      out = ResizeUrl.variants("https://example.test/a.jpg", [480, 720])

      assert out["raw"] == "https://example.test/a.jpg"
      assert out["w480"] =~ "w=480"
      assert out["w720"] =~ "w=720"
    end
  end
end
