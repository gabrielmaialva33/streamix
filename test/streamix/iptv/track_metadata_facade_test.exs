defmodule Streamix.Iptv.TrackMetadataFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.{Gindex, Iptv}
  alias Streamix.Iptv.{Episode, Season}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  setup do
    user = user_fixture()
    %{provider: provider_fixture(user)}
  end

  test "reads and updates a movie probe source through the IPTV facade", %{provider: provider} do
    movie = movie_fixture(provider, %{gindex_path: "/movies/demo.mkv"})
    metadata = %{"audio" => [%{"codec" => "aac"}], "subtitle" => []}

    assert {:ok, source} = Iptv.get_media_track_source(:movie, movie.id)
    assert source == %{id: movie.id, gindex_path: "/movies/demo.mkv", track_metadata: nil}

    assert :ok = Iptv.put_media_track_metadata(:movie, movie.id, metadata)
    assert {:ok, %{track_metadata: ^metadata}} = Iptv.get_media_track_source(:movie, movie.id)

    assert {:ok, %{audio: [%{"codec" => "aac"}], subtitle: [], probed_at: nil}} =
             Gindex.fetch_media_tracks(:movie, movie.id)
  end

  test "supports episode sources without exposing the episode schema", %{provider: provider} do
    series = series_content_fixture(provider)

    season =
      %Season{}
      |> Season.changeset(%{season_number: 1, name: "Season 1", series_id: series.id})
      |> Repo.insert!()

    episode =
      %Episode{}
      |> Episode.changeset(%{
        episode_id: 101,
        episode_num: 1,
        title: "Episode 1",
        season_id: season.id,
        catalog_item_id: catalog_item_fixture("episode", provider.id).id,
        gindex_path: "/series/demo-s01e01.mkv"
      })
      |> Repo.insert!()

    assert {:ok, source} = Iptv.get_media_track_source(:episode, episode.id)
    assert source.id == episode.id
    assert source.gindex_path == "/series/demo-s01e01.mkv"
  end

  test "returns explicit errors for missing and unsupported content", %{provider: provider} do
    missing_id = System.unique_integer([:positive])
    regular_movie = movie_fixture(provider)

    assert {:error, :not_found} = Iptv.get_media_track_source(:movie, missing_id)
    assert {:error, :not_found} = Iptv.put_media_track_metadata(:movie, missing_id, %{})

    assert {:error, :invalid_metadata} =
             Iptv.put_media_track_metadata(:movie, provider.id, "not-a-map")

    assert {:error, :unsupported_type} = Iptv.get_media_track_source(:live_channel, provider.id)
    assert {:error, :not_gindex} = Gindex.fetch_media_tracks(:movie, regular_movie.id)
  end
end
