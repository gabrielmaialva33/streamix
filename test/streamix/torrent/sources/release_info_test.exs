defmodule Streamix.Torrent.Sources.ReleaseInfoTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.Sources.ReleaseInfo

  describe "parse/1" do
    test "extracts title, year, quality and dual audio" do
      assert %{title: "Duna", year: 2021, quality: "1080p", audio_track: "dual"} =
               ReleaseInfo.parse("Duna (2021) Torrent - BluRay 1080p Dual Áudio")
    end

    test "detects dubbed releases" do
      assert %{audio_track: "dublado", quality: "720p", year: 2019} =
               ReleaseInfo.parse("Vingadores Ultimato 2019 720p WEB-DL Dublado")
    end

    test "detects legendado" do
      assert %{audio_track: "legendado"} =
               ReleaseInfo.parse("The Batman 2022 1080p BluRay Legendado")
    end

    test "dual wins over dublado when both present" do
      assert %{audio_track: "dual"} =
               ReleaseInfo.parse("Filme 2020 Dual Áudio Dublado 1080p")
    end

    test "maps 4k/uhd to 2160p" do
      assert %{quality: "2160p"} = ReleaseInfo.parse("Avatar 2009 4K UHD Dual")
    end

    test "nil audio when no flavor present" do
      assert %{audio_track: nil, title: "Tenet", year: 2020} =
               ReleaseInfo.parse("Tenet 2020 1080p BluRay x264")
    end

    test "handles empty and nil" do
      assert %{title: "", year: nil, quality: nil, audio_track: nil} = ReleaseInfo.parse("")
      assert %{title: "", year: nil} = ReleaseInfo.parse(nil)
    end

    test "does not treat resolution as the year" do
      assert %{year: 2021} = ReleaseInfo.parse("Filme 2021 1080p")
    end
  end
end
