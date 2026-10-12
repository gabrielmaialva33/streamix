defmodule Streamix.Gindex.Scraper.SeriesTest do
  @moduledoc """
  Covers title folders that keep their episodes loose instead of under a
  `Season NN/` subfolder.

  These used to resolve to `:empty`, which the scan reported as success: no
  error, no `skipped_count`, nothing in the logs. In production that silently
  dropped 39 of the 40 telenovelas under `/0:/Novelas/` and roughly a third of
  `/0:/Animes/`, while the scan root still finished as `completed`.
  """

  use ExUnit.Case, async: true

  alias Streamix.Gindex.Scraper.Series

  @base_url "https://gindex.example"

  describe "scrape_single_series_result/3 with loose episodes" do
    test "reads telenovela files numbered `E001` with no season marker" do
      folder = folder("A Dona do Pedaço (2019)")

      files = [
        file(folder, "A.Dona.do.Pedaço.E001.1080p.WEB-DL.AAC.h264-iND.mkv"),
        file(folder, "A.Dona.do.Pedaço.E002.1080p.WEB-DL.AAC.h264-iND.mkv"),
        file(folder, "A.Dona.do.Pedaço.E003.720p.WEB-DL.AAC.x264-iND.mkv")
      ]

      assert {:ok, series} = scrape(folder, files)
      assert [season] = series.seasons
      assert season.season_number == 1
      assert season.episode_count == 3
      assert Enum.map(season.episodes, & &1.episode_num) == [1, 2, 3]
      assert series.episode_count == 3
    end

    test "reads fansub anime files numbered `- 01`" do
      folder = folder(".hack SIGN")

      files = [
        file(folder, "[AniMercoSul] .hack SIGN - 01 [720p][Dual Áudio].mkv"),
        file(folder, "[AniMercoSul] .hack SIGN - 02 [720p][Dual Áudio].mkv")
      ]

      assert {:ok, series} = scrape(folder, files)
      assert [season] = series.seasons
      assert season.season_number == 1
      assert Enum.map(season.episodes, & &1.episode_num) == [1, 2]
    end

    test "splits into one season per season marker found in the filenames" do
      folder = folder("A Casa das Sete Mulheres (2003)")

      files = [
        file(folder, "A.Casa.das.Sete.Mulheres.S01E01.1080p.GLBO.WEB-DL.AAC2.0.H.264-PF.mkv"),
        file(folder, "A.Casa.das.Sete.Mulheres.S01E02.1080p.GLBO.WEB-DL.AAC2.0.H.264-PF.mkv"),
        file(folder, "A.Casa.das.Sete.Mulheres.S02E01.1080p.GLBO.WEB-DL.AAC2.0.H.264-PF.mkv")
      ]

      assert {:ok, series} = scrape(folder, files)
      assert [first, second] = series.seasons
      assert first.season_number == 1
      assert Enum.map(first.episodes, & &1.episode_num) == [1, 2]
      assert second.season_number == 2
      assert Enum.map(second.episodes, & &1.episode_num) == [1]
      assert series.season_count == 2
      assert series.episode_count == 3
    end

    test "splits a flat folder that mixes seasons in two notations" do
      # /1:/Séries/Séries Misturado/This Is Us/ really looks like this: some
      # files written `3x11`, others `S05e03`. Only the dotted form reported a
      # season, so the rest piled onto the folder's season and collided —
      # season 38843 in production holds 12 rows for three different seasons.
      folder = folder("This Is Us")

      files = [
        file(folder, "This Is Us - 3x11 - Songbird Road Part One.mkv"),
        file(folder, "This Is Us - 3x12 - Songbird Road Part Two.mkv"),
        file(folder, "This.Is.Us.S05e03.Changes.1080p.WEB-DL.DUAL.mkv"),
        file(folder, "This.Is.Us.S05e04.Honestly.1080p.WEB-DL.DUAL.mkv")
      ]

      assert {:ok, series} = scrape(folder, files)
      assert [third, fifth] = series.seasons
      assert third.season_number == 3
      assert Enum.map(third.episodes, & &1.episode_num) == [11, 12]
      assert fifth.season_number == 5
      assert Enum.map(fifth.episodes, & &1.episode_num) == [3, 4]
      assert series.season_count == 2
      assert series.episode_count == 4
    end

    test "keeps the folder's season for files that carry no marker" do
      folder = folder("A Dona do Pedaço (2019)")

      files = [
        file(folder, "A.Dona.do.Pedaço.E001.1080p.WEB-DL.mkv"),
        file(folder, "A.Dona.do.Pedaço.E002.1080p.WEB-DL.mkv")
      ]

      assert {:ok, series} = scrape(folder, files)
      assert [season] = series.seasons
      assert season.season_number == 1
    end

    test "anchors every episode to the file it came from" do
      folder = folder("7Seeds")
      files = [file(folder, "[Grupo] 7Seeds - 01 [1080p].mkv")]

      assert {:ok, series} = scrape(folder, files)
      assert [%{episodes: [episode]}] = series.seasons
      assert episode.gindex_path == "/0:/Animes/7Seeds/[Grupo] 7Seeds - 01 [1080p].mkv"
      assert episode.container_extension == "mkv"
      assert episode.file_size == 1024
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
               Series.scrape_single_series_result(@base_url, folder,
                 list_fun: fn _path, _base_url -> {:error, :upstream_unavailable} end
               )
    end
  end

  defp scrape(folder, items) do
    Series.scrape_single_series_result(@base_url, folder,
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
