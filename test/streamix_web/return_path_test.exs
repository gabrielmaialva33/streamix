defmodule StreamixWeb.ReturnPathTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.ReturnPath

  doctest ReturnPath

  describe "safe/1" do
    test "keeps a path on this site, query included" do
      assert ReturnPath.safe("/") == "/"

      assert ReturnPath.safe("/browse/movies?page=2&genre=drama") ==
               "/browse/movies?page=2&genre=drama"

      assert ReturnPath.safe("/search?q=a%20b") == "/search?q=a%20b"
    end

    test "rejects anything a browser would read as another host" do
      for value <- [
            "//evil.example",
            "/\\evil.example",
            "/\\/evil.example",
            "/\t/evil.example",
            "/ /evil.example",
            "/\n/evil.example",
            "/x\x00",
            "https://evil.example",
            "evil.example",
            "javascript:alert(1)",
            ""
          ] do
        assert ReturnPath.safe(value) == nil, "accepted #{inspect(value)}"
      end
    end

    test "rejects what is not a string" do
      assert ReturnPath.safe(nil) == nil
      assert ReturnPath.safe(["/"]) == nil
      assert ReturnPath.safe(%{"path" => "/"}) == nil
    end
  end

  describe "append/2" do
    test "adds return_to, keeping an existing query" do
      assert ReturnPath.append("/watch/movie/1", "/browse") ==
               "/watch/movie/1?return_to=%2Fbrowse"

      assert ReturnPath.append("/browse/series/2?season=3", "/search?q=x") ==
               "/browse/series/2?season=3&return_to=%2Fsearch%3Fq%3Dx"
    end

    test "leaves the path alone when return_to is missing or unsafe" do
      assert ReturnPath.append("/watch/movie/1", nil) == "/watch/movie/1"
      assert ReturnPath.append("/watch/movie/1", "/\\evil.example") == "/watch/movie/1"
      assert ReturnPath.append("/watch/movie/1", "//evil.example") == "/watch/movie/1"
    end
  end
end
