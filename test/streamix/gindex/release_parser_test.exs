defmodule Streamix.Gindex.ReleaseParserTest do
  use ExUnit.Case, async: true

  import Streamix.Gindex.ReleaseParser, only: [parse: 1]

  alias Streamix.Gindex.ReleaseParser

  doctest ReleaseParser

  describe "parse/1" do
    test "handles absent values" do
      assert ReleaseParser.parse(nil) == %{title: "", year: nil}
      assert ReleaseParser.parse("") == %{title: "", year: nil}
    end

    test "extracts the release year and strips scene metadata" do
      assert ReleaseParser.parse("A Era do Gelo 1 2002 1080p BluRay x264 Dual") == %{
               title: "A Era do Gelo 1",
               year: 2002
             }

      assert ReleaseParser.parse("[Sakurai] Movie.Title.2024.2160p.WEB-DL.DDP5.1.H.265-GROUP.mkv") ==
               %{title: "Movie Title", year: 2024}
    end

    test "recognizes parenthesized years without confusing resolutions or codecs" do
      assert ReleaseParser.parse("A Bela Adormecida (1959) [1080p BluRay DUAL]") == %{
               title: "A Bela Adormecida",
               year: 1959
             }

      assert ReleaseParser.parse("Documentário 1080p x264") == %{
               title: "Documentário",
               year: nil
             }
    end

    test "keeps meaningful numbers and hyphens in human titles" do
      assert ReleaseParser.parse("13 Reasons Why") == %{title: "13 Reasons Why", year: nil}
      assert ReleaseParser.parse("07-Ghost") == %{title: "07-Ghost", year: nil}

      assert ReleaseParser.parse("Spider-Man_No_Way_Home") == %{
               title: "Spider-Man No Way Home",
               year: nil
             }
    end

    test "strips localized audio and subtitle release tags" do
      assert ReleaseParser.parse("Central do Brasil 1998 Múltiplos Áudios PT-BR 5.1 REMUX.mkv") ==
               %{title: "Central do Brasil", year: 1998}

      assert ReleaseParser.parse("Cidade de Deus 2002 Áudio Dublado LEGENDADO.mkv") == %{
               title: "Cidade de Deus",
               year: 2002
             }
    end
  end
end
