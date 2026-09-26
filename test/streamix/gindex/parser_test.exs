defmodule Streamix.Gindex.ParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Parser

  describe "parse_anime_episode/1 — existing release patterns" do
    test "parses [Group] Name - NN [Quality].mkv" do
      result =
        Parser.parse_anime_episode("[Erai-raws] Spy x Family - 01 [1080p][Multiple Subtitle].mkv")

      assert result.episode == 1
      assert result.group == "Erai-raws"
      assert result.extension == "mkv"
    end

    test "parses release with dot-terminated episode" do
      result = Parser.parse_anime_episode("[SubsPlease] Bocchi - 12.mkv")
      assert result.episode == 12
    end
  end

  describe "parse_anime_episode/1 — PT-BR and fansub variants (regression)" do
    # These are releases the original regex silently dropped: without
    # the dash-bracket shape the old parser returned `episode: nil`,
    # the caller's `Enum.reject(&is_nil/1)` threw the whole file out,
    # and those releases never landed in the catalog.

    test "parses `[Group] Name 01 [720p].mkv` (no dash before number)" do
      result = Parser.parse_anime_episode("[Fansub] Violet Evergarden 07 [720p].mkv")
      assert result.episode == 7
    end

    test "parses `Name - Episódio 05.mkv` (PT-BR)" do
      result = Parser.parse_anime_episode("Hunter x Hunter - Episódio 05.mkv")
      assert result.episode == 5
    end

    test "parses `Episodio 10` with no accent" do
      result = Parser.parse_anime_episode("Naruto Episodio 10.mp4")
      assert result.episode == 10
    end

    test "parses `Ep 03` / `Ep.03` shorthand" do
      assert Parser.parse_anime_episode("One Piece Ep 03.mkv").episode == 3
      assert Parser.parse_anime_episode("One Piece Ep.03.mkv").episode == 3
    end

    test "parses underscore-delimited releases" do
      result = Parser.parse_anime_episode("Attack_on_Titan_22_1080p.mkv")
      assert result.episode == 22
    end

    test "parses numbered specials like `#12`" do
      result = Parser.parse_anime_episode("Tokyo Ghoul #12.mkv")
      assert result.episode == 12
    end
  end

  describe "parse_anime_episode/1 — explicit season/episode markers" do
    # Every filename here is taken verbatim from /0:/Animes/ in production.
    # Before these two patterns existed the names fell through to the
    # bare-number fallback, which takes the first 1-3 digit run in the string.
    # The damage was not just a wrong number: the ingest de-duplicates episodes
    # by `episode_num`, so a title whose files all scored the same number
    # collapsed to a single episode, and a title where nothing matched was
    # dropped entirely.

    test "parses `SxxEyy` instead of a digit run in the title" do
      # "009-1" scored 9 for every episode, collapsing 13 files into one.
      assert Parser.parse_anime_episode(
               "[Troidex][danfgtn] 009-1 (2006) - S01E01 [DVD-Rip_720p_x264_Dual].mkv"
             ).episode == 1

      assert Parser.parse_anime_episode(
               "[Troidex][danfgtn] 009-1 (2006) - S01E12 [DVD-Rip_720p_x264_Dual].mkv"
             ).episode == 12
    end

    test "parses `SxxEyy` in dotted release names" do
      assert Parser.parse_anime_episode(
               "Cherry.Magic!.Thirty.Years.of.Virginity.S01E07.1080p.CR.WEB-DL.x264.mkv"
             ).episode == 7
    end

    test "parses the `1x01` season-by-episode shape" do
      assert Parser.parse_anime_episode(
               "ABCiee Working Diary - 1x01 - Newbie ABCiee Is Going to Do His Best.mkv"
             ).episode == 1

      assert Parser.parse_anime_episode(
               "Magical Shopping Arcade Abenobashi - 1x13 - Farewell! [Abenobashi].avi"
             ).episode == 13
    end

    test "prefers `1x01` over a digit run in the title" do
      # "ACCA 13-Territory" scored 13 for all 12 episodes.
      assert Parser.parse_anime_episode(
               "ACCA 13-Territory Inspection Dept. - 1x04 - Smoldering Embers.mkv"
             ).episode == 4
    end

    test "does not read a resolution as a season-by-episode marker" do
      # `1280x720` must not parse as season 1280, episode 720: the leading
      # digit run is four long, so the marker cannot start inside it.
      assert Parser.parse_anime_episode("[KO] Aikatsu on Parade! - 05 [HD 1280x720 AAC].mkv").episode ==
               5

      assert Parser.parse_anime_episode("Show Name [720x480 DVD].mkv").episode == nil
    end
  end

  describe "parse_anime_episode/1 — fallback doesn't confuse year/resolution with episode" do
    test "ignores year in parentheses" do
      # Regression: a naive `\d+` match would collapse `(2021)` to
      # episode 21, polluting the catalog with bogus episodes.
      result = Parser.parse_anime_episode("Movie Name (2021).mkv")
      assert result.episode == nil
    end

    test "ignores resolution tokens" do
      result = Parser.parse_anime_episode("Name 1080p.mkv")
      assert result.episode == nil
    end

    test "still parses when a clean number exists alongside resolution" do
      # `1080p` gets scrubbed; `07` is the real episode.
      result = Parser.parse_anime_episode("Show 07 1080p BluRay.mkv")
      assert result.episode == 7
    end
  end

  describe "video_file?/1 — extended extension whitelist" do
    test "accepts legacy/fansub formats the original list dropped" do
      for ext <- ~w(ts m2ts mpg mpeg ogv 3gp) do
        assert Parser.video_file?("example.#{ext}"),
               "expected .#{ext} to be recognised as a video file"
      end
    end

    test "still accepts the common modern formats" do
      for ext <- ~w(mkv mp4 avi mov webm m4v) do
        assert Parser.video_file?("example.#{ext}")
      end
    end

    test "rejects non-video extensions" do
      refute Parser.video_file?("example.srt")
      refute Parser.video_file?("example.nfo")
      refute Parser.video_file?("example.jpg")
    end
  end
end
