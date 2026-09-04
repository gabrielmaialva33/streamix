defmodule StreamixWeb.Content.HelperComponentsTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.Content.HelperComponents

  describe "episode_title/1" do
    # `name` holds the raw filename for 102.209 of the catalog's 104.975
    # episodes, so the detail page was labelling episodes with a release string.
    # Provenance, the same argument as `channels` over a release string on an
    # audio track: TMDB names an episode by its number in a season it curates,
    # while `title` came out of a filename.
    test "prefers TMDB's episode name over both stored fields" do
      episode = %{
        tmdb_title: "O Janelão",
        title: "A Caverna Encantada S01 E01",
        name: "A.Caverna.Encantada.S01E01.1080p.WEB-DL.mkv",
        episode_num: 1
      }

      assert HelperComponents.episode_title(episode) == "O Janelão"
    end

    test "falls back to the stored title when TMDB had no name" do
      episode = %{tmdb_title: nil, title: "Steve Vs Sidney", name: "arquivo.mkv", episode_num: 19}

      assert HelperComponents.episode_title(episode) == "Steve Vs Sidney"
    end

    test "prefers the title over the filename in name" do
      episode = %{
        title: "Steve Vs Sidney",
        name: "Irmao.Do.Jorel.S03E19.Steve.Vs.Sidney.1080p.HMAX.WEB-DL.DD2.0.x264-Yatogam1.mkv",
        episode_num: 19
      }

      assert HelperComponents.episode_title(episode) == "Steve Vs Sidney"
    end

    test "falls back to the name when there is no title" do
      episode = %{title: nil, name: "As Aventuras de Jackie Chan", episode_num: 11}

      assert HelperComponents.episode_title(episode) == "As Aventuras de Jackie Chan"
    end

    test "treats a blank title as absent" do
      episode = %{title: "   ", name: "Um Nome", episode_num: 3}

      assert HelperComponents.episode_title(episode) == "Um Nome"
    end

    test "numbers the episode when it has neither" do
      assert HelperComponents.episode_title(%{title: nil, name: nil, episode_num: 7}) ==
               "Episódio 7"
    end

    test "accepts the `num` key used by the card components" do
      assert HelperComponents.episode_title(%{title: nil, name: nil, num: 4}) == "Episódio 4"
    end

    # The provider's own parse leaves scene tokens on some stored titles —
    # 9.435 of them carry codec or resolution markers.
    test "shaves scene noise off a stored title" do
      episode = %{
        title: "A banda O hidrante dourado DD+2 H 264-alfaHD",
        name: nil,
        episode_num: 8
      }

      assert HelperComponents.episode_title(episode) == "A banda O hidrante dourado -alfaHD"
    end

    test "keeps the raw value when cleaning would empty it" do
      episode = %{title: "1080p", name: nil, episode_num: 1}

      assert HelperComponents.episode_title(episode) == "1080p"
    end
  end
end
