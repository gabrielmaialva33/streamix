defmodule StreamixWeb.PlayerComponents.MetadataTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.PlayerComponents.Metadata

  test "keeps signed and torrent URLs inside the application proxy contract" do
    signed = "/api/stream/proxy?token=signed-value"
    torrent = "/api/stream/torrent/abc123"

    assert Metadata.proxy_url(signed, :movie) == signed
    assert Metadata.proxy_url(torrent, :torrent) == torrent

    direct = "https://provider.example/movie name.mkv"
    proxy_base = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

    assert Metadata.proxy_url(direct, :movie) ==
             "#{proxy_base}/proxy?url=#{URI.encode_www_form(direct)}"
  end

  test "derives stable stream hints from content and provider metadata" do
    assert Metadata.stream_type_hint(:live_channel, %{}, :xtream) == "ts"
    assert Metadata.stream_type_hint(:torrent, %{}, :torrent) == "mp4"

    assert Metadata.stream_type_hint(:gindex, %{gindex_path: "/Filmes/Movie.MKV"}, "gindex") ==
             "mkv"

    assert Metadata.stream_type_hint(:movie, %{container_extension: "avi"}, :xtream) == "avi"
  end

  test "builds episode title and subtitle from nested context" do
    episode = %{
      episode_num: 3,
      season: %{season_number: 2, series: %{name: "Example Series"}}
    }

    assert Metadata.title(episode, :episode) == "Episódio 3"
    assert Metadata.episode_subtitle(episode) == "T2:E3"
    assert Metadata.subtitle(episode, :episode) == "Example Series - T2:E3"
  end

  test "detects the heavy 4K HEVC playback tier without classifying ordinary media" do
    assert Metadata.uhd_hevc?(%{gindex_path: "/Filmes/Movie.2160p.HEVC.mkv"})
    assert Metadata.uhd_hevc?(%{title: "Movie 4K"})
    refute Metadata.uhd_hevc?(%{title: "Movie 1080p H264"})
  end
end
