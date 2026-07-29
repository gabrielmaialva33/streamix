defmodule Streamix.Gindex.Parser.ReleaseFolderTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Parser.ReleaseFolder

  test "returns an explicit empty release for nil" do
    assert ReleaseFolder.parse(nil) == %{
             group: nil,
             is_dual: false,
             quality: nil,
             source: nil,
             codec: nil,
             score: 0,
             raw_name: nil
           }
  end

  test "extracts release traits and calculates their weighted score" do
    assert ReleaseFolder.parse("Erai-raws - 2160p BDRemux HEVC Dual") == %{
             group: "Erai",
             is_dual: true,
             quality: "2160p",
             source: "BDRemux",
             codec: "HEVC",
             score: 95,
             raw_name: "Erai-raws - 2160p BDRemux HEVC Dual"
           }
  end

  test "extracts a parenthesized group when there is no release prefix" do
    assert ReleaseFolder.parse("1080p WEB-DL x264 (SubsPlease)") == %{
             group: "SubsPlease",
             is_dual: false,
             quality: "1080p",
             source: "WEB-DL",
             codec: "H.264",
             score: 50,
             raw_name: "1080p WEB-DL x264 (SubsPlease)"
           }
  end

  test "recognizes lower-quality source variants" do
    assert %{quality: "720p", source: "WEBRip", score: 30} =
             ReleaseFolder.parse("Group - 720p WEBRip")

    assert %{quality: "480p", source: "HDTV", score: 15} =
             ReleaseFolder.parse("Group - 480p HDTV")

    assert %{quality: "2160p", source: "BD", codec: "HEVC", score: 70} =
             ReleaseFolder.parse("Group - 4K Bluray H.265")
  end

  test "preserves an unknown release without manufacturing metadata" do
    assert ReleaseFolder.parse("  Custom release folder  ") == %{
             group: nil,
             is_dual: false,
             quality: nil,
             source: nil,
             codec: nil,
             score: 0,
             raw_name: "Custom release folder"
           }
  end
end
