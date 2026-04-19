defmodule Streamix.Iptv.Gindex.ParserTest do
  use ExUnit.Case, async: true

  alias Streamix.Iptv.Gindex.Parser

  describe "parse_anime_episode/1 — existing release patterns" do
    test "parses [Group] Name - NN [Quality].mkv" do
      result = Parser.parse_anime_episode("[Erai-raws] Spy x Family - 01 [1080p][Multiple Subtitle].mkv")
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
