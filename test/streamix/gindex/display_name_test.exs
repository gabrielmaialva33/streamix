defmodule Streamix.Gindex.DisplayNameTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.DisplayName

  describe "clean_title/1" do
    test "returns an empty title for absent values" do
      assert DisplayName.clean_title(nil) == ""
      assert DisplayName.clean_title("") == ""
    end

    test "uses the release parser but preserves an otherwise empty raw title" do
      assert DisplayName.clean_title("Movie.Title.2024.1080p.WEB-DL.mkv") == "Movie Title"
      assert DisplayName.clean_title("1080p") == "1080p"
    end
  end

  describe "clean_episode/1" do
    test "removes extensions and release noise while preserving episode identity" do
      assert DisplayName.clean_episode("1883 - S01E01 - 1883 WEBDL-1080p.mkv") ==
               "1883 - S01E01 - 1883"

      assert DisplayName.clean_episode("[Ambient][MDAN] Show.S2-E7.Episode.Title.[720p].x264.mkv") ==
               "Show S2-E7 Episode Title"
    end

    test "drops noise-only groups but preserves meaningful bracket text" do
      assert DisplayName.clean_episode("Show [Directors Cut] (WEB-DL 1080p) S01E02.mkv") ==
               "Show [Directors Cut] S01E02"

      assert DisplayName.clean_episode("Show [25] S01E03.mkv") == "Show S01E03"
    end

    test "normalizes repeated separators without damaging hyphenated titles" do
      assert DisplayName.clean_episode("-- Show - - WEB-DL __ S01E01 --.mkv") ==
               "Show - S01E01"

      assert DisplayName.clean_episode("07-Ghost.mkv") == "07-Ghost"
    end

    test "handles absent values" do
      assert DisplayName.clean_episode(nil) == ""
      assert DisplayName.clean_episode("") == ""
    end
  end

  describe "episode_label/1" do
    test "normalizes SxxEyy markers" do
      assert DisplayName.episode_label("Show.S2-E7.1080p.mkv") == "S02E07"
      assert DisplayName.episode_label("Show s01e123.mkv") == "S01E123"
    end

    test "falls back to separated leading and trailing episode numbers" do
      assert DisplayName.episode_label("07 - Ghost WEB-DL 1080p.mkv") == "Ep 07"
      assert DisplayName.episode_label("Show - 12") == "Ep 12"
    end

    test "does not mistake a title number for an episode" do
      assert DisplayName.episode_label("07-Ghost.mkv") == nil
      assert DisplayName.episode_label("No marker here.mkv") == nil
      assert DisplayName.episode_label(nil) == nil
      assert DisplayName.episode_label("") == nil
    end
  end
end
