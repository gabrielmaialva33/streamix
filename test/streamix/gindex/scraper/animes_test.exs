defmodule Streamix.Gindex.Scraper.AnimesTest do
  @moduledoc """
  Covers anime title folders that keep their episodes loose instead of under a
  `[Group] Title 1080p/` release subfolder.

  These used to resolve to `:empty`, which the scan reported as success: no
  error, no `skipped_count`, nothing in the logs. `Scraper.Series` already
  handled the shape, but `/0:/Animes/` is dispatched with `kind: :animes` and
  runs through this module instead, so the titles kept being dropped. Measured
  against production: 36 of the first 100 folders under `/0:/Animes/` are
  flat, holding 12 to 48 loose episodes each.
  """

  use ExUnit.Case, async: true

  alias Streamix.Gindex.Scraper.Animes

  @base_url "https://gindex.example"

  describe "scrape_single_anime_result/3 with loose episodes" do
    test "reads fansub files numbered `- 01`" do
      folder = folder(".hack SIGN")

      files = [
        file(folder, "[AniMercoSul] .hack SIGN - 01 [720p][Dual Áudio].mkv"),
        file(folder, "[AniMercoSul] .hack SIGN - 02 [720p][Dual Áudio].mkv"),
        file(folder, "[AniMercoSul] .hack SIGN - 03 [720p][Dual Áudio].mkv")
      ]

      assert {:ok, anime} = scrape(folder, files)
      assert [release] = anime.seasons
      assert release.season_number == 1
      assert Enum.map(release.episodes, & &1.episode_num) == [1, 2, 3]
      assert anime.episode_count == 3
      assert anime.content_type == "anime"
    end

    test "reads files numbered `SxxEyy` without collapsing them onto one number" do
      folder = folder("009-1")

      files = [
        file(folder, "[Troidex][danfgtn] 009-1 (2006) - S01E01 [DVD-Rip_720p_x264_Dual].mkv"),
        file(folder, "[Troidex][danfgtn] 009-1 (2006) - S01E02 [DVD-Rip_720p_x264_Dual].mkv"),
        file(folder, "[Troidex][danfgtn] 009-1 (2006) - S01E03 [DVD-Rip_720p_x264_Dual].mkv")
      ]

      assert {:ok, anime} = scrape(folder, files)
      assert [release] = anime.seasons
      assert Enum.map(release.episodes, & &1.episode_num) == [1, 2, 3]
    end

    test "reads files numbered `1x01`" do
      folder = folder("ABCiee Shuugyou Nikki")

      files = [
        file(folder, "ABCiee Working Diary - 1x01 - Newbie ABCiee Is Going to Do His Best.mkv"),
        file(folder, "ABCiee Working Diary - 1x02 - Oh, So Cute! The Female Announcer.mkv")
      ]

      assert {:ok, anime} = scrape(folder, files)
      assert [release] = anime.seasons
      assert Enum.map(release.episodes, & &1.episode_num) == [1, 2]
    end

    test "anchors every episode to the file it came from" do
      folder = folder("7Seeds")
      files = [file(folder, "[Grupo] 7Seeds - 01 [1080p].mkv")]

      assert {:ok, anime} = scrape(folder, files)
      assert [%{episodes: [episode]}] = anime.seasons
      assert episode.gindex_path == "/0:/Animes/7Seeds/[Grupo] 7Seeds - 01 [1080p].mkv"
      assert episode.container_extension == "mkv"
      assert episode.file_size == 1024
      assert episode.season_number == 1
    end

    test "reports neutral release metadata, since there is no release folder to rank" do
      folder = folder("7Seeds")
      files = [file(folder, "[Grupo] 7Seeds - 01 [1080p].mkv")]

      assert {:ok, %{seasons: [release]}} = scrape(folder, files)
      assert release.release_score == 0
      assert release.release_group == nil
      assert release.quality == nil
      assert release.is_dual == false
      assert release.gindex_path == folder.path
    end

    test "still reports :empty when the loose files carry no episode number" do
      folder = folder("Arquivos internos")

      files = [
        file(folder, "trailer.mkv"),
        file(folder, "bloopers.mkv")
      ]

      assert :empty == scrape(folder, files)
    end

    test "still reports :empty when the folder holds no video at all" do
      folder = folder("Temp")

      files = [
        file(folder, "capa.jpg"),
        file(folder, "leiame.txt")
      ]

      assert :empty == scrape(folder, files)
    end

    test "surfaces a listing failure instead of swallowing it as empty" do
      folder = folder("7Seeds")

      assert {:error, :upstream_unavailable} ==
               Animes.scrape_single_anime_result(@base_url, folder,
                 list_fun: fn _path, _base_url -> {:error, :upstream_unavailable} end
               )
    end
  end

  defp scrape(folder, items) do
    Animes.scrape_single_anime_result(@base_url, folder,
      list_fun: fn _path, _base_url -> {:ok, items} end
    )
  end

  defp folder(name) do
    %{
      name: name,
      type: :folder,
      path: "/0:/Animes/#{name}/",
      size: 0,
      mime_type: "",
      modified: nil
    }
  end

  defp file(folder, name) do
    %{
      name: name,
      type: :file,
      path: folder.path <> name,
      size: 1024,
      mime_type: "video/x-matroska",
      modified: nil
    }
  end
end
