defmodule Streamix.Torrent.Sources.YtsTest do
  use ExUnit.Case, async: true

  alias Streamix.Torrent.Sources.Yts

  @movie_payload %{
    "id" => 76_117,
    "imdb_code" => "tt15505004",
    "title" => "Poison Candy",
    "title_english" => "Poison Candy",
    "year" => 2022,
    "rating" => 5.9,
    "runtime" => 92,
    "genres" => ["Drama"],
    "summary" => "short summary",
    "description_full" => "long description",
    "synopsis" => "syn",
    "background_image_original" => "https://yts.bz/bg.jpg",
    "large_cover_image" => "https://yts.bz/large.jpg",
    "medium_cover_image" => "https://yts.bz/med.jpg",
    "torrents" => [
      %{
        "hash" => "5B6E178EC1C77D932068BE9BE185BAD19D564C49",
        "quality" => "1080p",
        "video_codec" => "x265",
        "audio_channels" => "5.1",
        "size_bytes" => 1_500_000_000,
        "seeds" => 42,
        "peers" => 7
      },
      %{
        "hash" => "62262C6B459177F4620F6ADF911F4D1299FBB308",
        "quality" => "3D",
        "video_codec" => "x264",
        "audio_channels" => "2.0",
        "size_bytes" => 2_500_000_000,
        "seeds" => 1,
        "peers" => 0
      }
    ]
  }

  describe "metadata" do
    test "slug + name + rate_limit_ms are stable" do
      assert Yts.slug() == "yts"
      assert Yts.name() == "YTS"
      assert is_integer(Yts.rate_limit_ms()) and Yts.rate_limit_ms() > 0
    end
  end

  describe "decode_movie via fetch_listing happy path" do
    @tag :integration
    test "fetches the live API and shapes one item correctly" do
      # Marked :integration so the default suite doesn't depend on the
      # YTS API being reachable. Run with `mix test --only integration`.
      assert {:ok, [first | _], meta} = Yts.fetch_listing(limit: 1)

      assert is_binary(first.external_id)
      assert is_binary(first.title)
      assert is_list(first.torrents)
      assert is_integer(meta.total) and meta.total > 0

      Enum.each(first.torrents, fn torrent ->
        assert byte_size(torrent.info_hash) == 40
        assert String.starts_with?(torrent.magnet_uri, "magnet:?")
        assert torrent.source_slug == "yts"
      end)
    end
  end

  # Pure decoding — no HTTP. Exercises the shape conversions that the
  # integration test can't pin down because the live data is volatile.
  describe "decode_movie/1 (private surface, exercised through fixture)" do
    test "synthesizes magnet URIs with the curated tracker list" do
      [item] = decode([@movie_payload])

      assert item.title == "Poison Candy"
      assert item.year == 2022
      assert item.imdb_id == "tt15505004"
      assert item.rating == 5.9
      assert item.runtime_minutes == 92
      assert item.poster_url == "https://yts.bz/large.jpg"
      assert item.backdrop_url == "https://yts.bz/bg.jpg"
      # Pulls description_full first when populated.
      assert item.plot == "long description"

      assert length(item.torrents) == 2
      [t1080, t3d] = item.torrents

      assert t1080.info_hash == "5b6e178ec1c77d932068be9be185bad19d564c49"
      assert t1080.quality == "1080p"
      assert t1080.codec == "x265"
      assert t1080.size_bytes == 1_500_000_000
      assert t1080.seeders == 42
      assert t1080.leechers == 7
      assert t1080.source_slug == "yts"
      assert String.starts_with?(t1080.magnet_uri, "magnet:?xt=urn:btih:5b6e178e")

      # 3D gets normalized to nil — we don't surface it as its own tier.
      assert t3d.quality == nil
    end

    test "title_english falls back to title when missing" do
      payload = Map.delete(@movie_payload, "title_english")
      [item] = decode([payload])
      assert item.title == "Poison Candy"
    end

    test "tolerates missing optional fields" do
      payload = %{"id" => 1, "title" => "X", "torrents" => []}
      [item] = decode([payload])

      assert item.year == nil
      assert item.imdb_id == nil
      assert item.poster_url == nil
      assert item.plot == nil
      assert item.rating == nil
      assert item.runtime_minutes == nil
      assert item.genres == []
      assert item.torrents == []
    end
  end

  defp decode(movies), do: Enum.map(movies, &Yts.decode_movie/1)
end
