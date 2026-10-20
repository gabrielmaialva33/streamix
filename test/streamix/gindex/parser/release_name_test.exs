defmodule Streamix.Gindex.Parser.ReleaseNameTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Parser.ReleaseName

  describe "parse_release_name/1 year" do
    test "the last plausible year is the release's; a number in the title stays" do
      assert %{name: "Blade Runner 2049", year: 2017, quality: "1080p"} =
               ReleaseName.parse_release_name("Blade.Runner.2049.2017.1080p.WEB-DL.mkv")

      assert %{name: "1917", year: 2019} =
               ReleaseName.parse_release_name("1917.2019.1080p.BluRay.mkv")
    end

    test "a year past next year is part of the title" do
      assert %{name: "Blade Runner 2049 1080p", year: nil} =
               ReleaseName.parse_release_name("Blade.Runner.2049.1080p.mkv")
    end

    test "a lone leading year is still read as the year" do
      assert %{name: "", year: 2012} = ReleaseName.parse_release_name("2012.1080p.mkv")
      assert %{name: "Duna", year: 2021} = ReleaseName.parse_release_name("Duna.2021.mkv")
    end
  end
end
