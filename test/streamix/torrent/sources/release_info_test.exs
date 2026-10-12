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

    test "a parenthesised year wins over a year inside the title" do
      assert %{title: "Blade Runner 2049", year: 2017} =
               ReleaseInfo.parse("Blade Runner 2049 (2017) Torrent Dual Áudio 1080p")
    end

    test "keeps a title that is itself a year" do
      assert %{title: "1917"} = ReleaseInfo.parse("1917 1080p Dublado")
    end

    test "strips GratisTorrent suffixes from the title" do
      assert %{title: "Little Town", year: 2024} =
               ReleaseInfo.parse(
                 "Little Town - Legendado e Dublado Não Oficial (2024)  - Download"
               )

      assert %{title: "Trauma Therapy - Psychosis"} =
               ReleaseInfo.parse("Trauma Therapy - Psychosis - FAN DUB (2023) - Download")

      assert %{title: "Ponto Sem Retorno", year: 2026} =
               ReleaseInfo.parse("Ponto Sem Retorno - CAM - Legendado (2026)  - Download")
    end

    test "clean releases carry no flags" do
      assert %{flags: [], audio_track: "dual"} =
               ReleaseInfo.parse(
                 "Matrix: Resurrections Torrent (2022) Dual Áudio 5.1 WEB-DL 1080p"
               )
    end
  end

  describe "unofficial dubs" do
    test "flags \"Dublado Não Oficial\" and never reports it as an official dub" do
      assert %{audio_track: "dublado_nao_oficial", flags: ["unofficial_dub"]} =
               ReleaseInfo.parse("Little Town - Legendado e Dublado Não Oficial (2024)")
    end

    test "flags \"Fan Dub\"" do
      assert %{audio_track: "dublado_nao_oficial", flags: ["unofficial_dub"]} =
               ReleaseInfo.parse("Trauma Therapy - Psychosis - FAN DUB (2023)")
    end

    test "flags scene names that announce an unofficial PT-BR track" do
      assert ReleaseInfo.unofficial_dub?(
               "VAMOSTORRENT.COM.VERSAO-MKV-PT-BR-NAO-OFICIAL.Trauma.Therapy.2023.1080p.Dublado.mkv"
             )
    end

    test "an unofficial subtitle is not an unofficial dub" do
      refute ReleaseInfo.unofficial_dub?("Filme 2024 Legendado (Legenda Não Oficial)")
      assert %{flags: []} = ReleaseInfo.parse("Filme (2024) Legendado - Legenda Não Oficial")
    end
  end

  describe "camera captures" do
    test "flags CAM, CAMRip, HDCAM, TS-cam and telesync" do
      for title <- [
            "Ponto Sem Retorno - CAM - Legendado (2026)",
            "The.Dog.Stars.2026.1080p.CAMRip.ENG.mkv",
            "Filme 2026 HDCAM Dublado",
            "Filme 2026 TS-cam Dual Áudio",
            "Filme 2026 HD-TS 720p",
            "Filme.2026.TELESYNC.x264",
            "Filme 2026 TS Dublado"
          ] do
        assert "cam" in ReleaseInfo.parse(title).flags, title
      end
    end

    test "does not mistake words containing \"cam\" or a lower-case ts for a capture" do
      for title <- ["Caminhos Cruzados (2021) Dual", "Camila 2020 1080p", "Fists.2020.1080p.WEB"] do
        assert ReleaseInfo.parse(title).flags == [], title
      end
    end
  end

  describe "for_magnet/3" do
    test "the magnet's own label beats the post title" do
      post = "Matrix: Resurrections Torrent (2022) Dual Áudio 5.1"

      assert %{audio_track: "legendado", quality: "2160p", flags: []} =
               ReleaseInfo.for_magnet(
                 post,
                 "DOWNLOAD TORRENT LEGENDADO 5.1 MKV 2160P ULTRA HD 4K",
                 ""
               )
    end

    test "falls back to the section heading, then to the post title" do
      post = "Matrix: Resurrections Torrent (2022) Dual Áudio 5.1"
      scene = "WEB-DL 2160p 4K (MKV) | 19.19 GB The.Matrix.4.Resurrections.2021.2160p.WEB.H265"

      assert %{audio_track: "legendado"} = ReleaseInfo.for_magnet(post, scene, ":: LEGENDADO ::")
      assert %{audio_track: "dual"} = ReleaseInfo.for_magnet(post, scene, "")
    end

    test "an unofficial dub post does not taint its subtitled file" do
      post = "Little Town - Legendado e Dublado Não Oficial (2024)"

      assert %{audio_track: "dublado_nao_oficial", flags: ["unofficial_dub"]} =
               ReleaseInfo.for_magnet(post, "DOWNLOAD TORRENT DUBLADO MKV 1080P", "")

      assert %{audio_track: "legendado", flags: []} =
               ReleaseInfo.for_magnet(post, "DOWNLOAD TORRENT LEGENDADO MKV 1080P", "")
    end

    test "a camera post flags every file" do
      post = "Ponto Sem Retorno - CAM - Legendado (2026)"
      assert %{flags: ["cam"]} = ReleaseInfo.for_magnet(post, "DOWNLOAD TORRENT 1080P", "")
    end
  end

  describe "series?/1 and bundle?/1" do
    test "recognise seasons and miniseries in titles and URL slugs" do
      assert ReleaseInfo.series?("lanternas-1a-temporada-torrent-2026-dual-audio")
      assert ReleaseInfo.series?("Patrulha Canina - 1ª Temporada")
      assert ReleaseInfo.series?("Miss Scarlet and The Duke - Minissérie")
      assert ReleaseInfo.series?("Show.S02E05.1080p")
      refute ReleaseInfo.series?("Matrix Resurrections (2022)")
    end

    test "recognise multi-movie bundles" do
      assert ReleaseInfo.bundle?("matrix-todos-os-filmes-download-torrent")
      assert ReleaseInfo.bundle?("Matrix Trilogia")
      assert ReleaseInfo.bundle?("listao-de-filmes-classicos-bluray")
      refute ReleaseInfo.bundle?("Matrix Reloaded (2003)")
    end
  end
end
