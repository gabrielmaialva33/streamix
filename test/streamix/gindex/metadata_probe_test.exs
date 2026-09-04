defmodule Streamix.Gindex.MetadataProbeTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Gindex
  alias Streamix.Iptv.Movie
  alias Streamix.Repo

  # Every distinct track title in the production catalog carries a release
  # group's watermark. These are the real ones.
  @real_titles [
    {"COMANDO.TO", nil},
    {"LAPUMiA", nil},
    {"LAPUMiAFiLMES.COM", nil},
    {"WWW.BLUDV.COM", nil},
    # The layout survives in `channels`, so what is left here is not a label.
    {"WWW.BLUDV.COM 5.1 [BR]", nil},
    # The two that carry something worth keeping — dropping the whole title on
    # a watermark would lose exactly these.
    {"Inglês 5.1 - LAPUMiA", "Inglês 5.1"},
    {"Português 2.0 - LAPUMiA", "Português 2.0"}
  ]

  setup do
    %{provider: global_provider_fixture(%{provider_type: :gindex})}
  end

  describe "watermark stripping on read" do
    for {raw, expected} <- @real_titles do
      test "#{inspect(raw)} reads back as #{inspect(expected)}", %{provider: provider} do
        movie = probed_movie(provider, unquote(raw))

        assert {:ok, %{audio: [track]}} = Gindex.fetch_media_tracks(:movie, movie.id)
        assert track["title"] == unquote(expected)
      end
    end

    test "leaves a title that carries no watermark alone", %{provider: provider} do
      movie = probed_movie(provider, "Comentários do Diretor")

      assert {:ok, %{audio: [track]}} = Gindex.fetch_media_tracks(:movie, movie.id)
      assert track["title"] == "Comentários do Diretor"
    end

    test "keeps a nil title nil", %{provider: provider} do
      movie = probed_movie(provider, nil)

      assert {:ok, %{audio: [track]}} = Gindex.fetch_media_tracks(:movie, movie.id)
      assert track["title"] == nil
    end

    test "carries the rest of the track through untouched", %{provider: provider} do
      movie = probed_movie(provider, "WWW.BLUDV.COM")

      assert {:ok, %{audio: [track], subtitle: [], probed_at: probed_at}} =
               Gindex.fetch_media_tracks(:movie, movie.id)

      assert track["index"] == 1
      assert track["codec"] == "ac3"
      assert track["language"] == "por"
      assert track["channels"] == 6
      assert track["default"]
      assert probed_at == "2026-09-04T18:32:16Z"
    end
  end

  defp probed_movie(provider, title) do
    movie = movie_fixture(provider, %{gindex_path: "/1:/Filmes/Teste/teste.mkv"})

    metadata = %{
      "audio" => [
        %{
          "index" => 1,
          "codec" => "ac3",
          "language" => "por",
          "title" => title,
          "channels" => 6,
          "default" => true,
          "forced" => false
        }
      ],
      "subtitle" => [],
      "probed_at" => "2026-09-04T18:32:16Z"
    }

    Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
      set: [track_metadata: metadata]
    )

    movie
  end
end
