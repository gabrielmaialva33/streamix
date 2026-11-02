defmodule Streamix.Iptv.VodAvailabilityTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures
  alias Streamix.Iptv
  alias Streamix.Iptv.Content.EnrichmentFields
  alias Streamix.Iptv.{Episode, Movie, Season}

  test "only definitive 404 and 410 mark the owned movie asynchronously" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)

    for reason <- [
          :timeout,
          {:unexpected_status, 403},
          {:unexpected_status, 500},
          :upstream_unavailable
        ] do
      assert :ok = Iptv.record_vod_failure("movie", movie.id, provider.id, reason)
      refute Repo.get!(Movie, movie.id).dead_since
    end

    await_mark("movie", movie.id, provider.id, {:unexpected_status, 404})
    assert Repo.get!(Movie, movie.id).dead_since

    other = global_provider_fixture()
    alive = movie_fixture(provider)
    await_mark(:movie, alive.id, other.id, {:http_error, 410})
    refute Repo.get!(Movie, alive.id).dead_since
    await_mark(:movie, alive.id, provider.id, {:http_error, 410})
    assert Repo.get!(Movie, alive.id).dead_since
  end

  test "episodes are scoped through their provider and transient errors never hide them" do
    provider = global_provider_fixture()
    episode = episode_fixture(provider)

    assert :ok =
             Iptv.record_vod_failure(:episode, episode.id, provider.id, {:unexpected_status, 503})

    await_mark(:episode, episode.id, provider.id, :upstream_not_found)
    assert Iptv.vod_dead?(Repo.get!(Episode, episode.id))
    assert Iptv.list_season_episodes(episode.season_id) == []
  end

  test "public, provider, search, ranking and home shelves hide dead movies until the seven day recheck" do
    provider = global_provider_fixture()

    movie =
      movie_fixture(provider, %{
        name: "Unavailable title",
        title: "Unavailable title",
        stream_icon: "/cover.jpg"
      })

    await_mark(:movie, movie.id, provider.id, {:unexpected_status, 404})
    assert Iptv.get_movies_by_ids([movie.id]) == []
    assert Iptv.list_movies(provider.id) == []
    assert Streamix.Catalog.list_public_catalog_movies([]) == []
    assert Iptv.search_public_movies("Unavailable") == []
    assert Streamix.Catalog.list_public_movies_by_ids([movie.id]) == []
    assert Iptv.list_recent_movies([]) == []
    assert Streamix.Playback.get_movie_for_stream(movie.id) == nil

    old = DateTime.utc_now(:second) |> DateTime.add(-8, :day)
    Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [dead_since: old])
    refute Iptv.vod_dead?(Repo.get!(Movie, movie.id))
    assert Enum.any?(Iptv.list_movies(provider.id), &(&1.id == movie.id))
    assert Streamix.Playback.get_movie_for_stream(movie.id)
  end

  test "episode details and next episode skip missing files" do
    provider = global_provider_fixture()
    first = episode_fixture(provider)
    second = episode_in_season(first.season_id, provider.id, 2)
    third = episode_in_season(first.season_id, provider.id, 3)
    await_mark(:episode, second.id, provider.id, {:unexpected_status, 410})
    assert Enum.map(Iptv.list_season_episodes(first.season_id), & &1.id) == [first.id, third.id]
    assert Iptv.get_next_episode(first.id).id == third.id
    assert Streamix.Playback.get_episode_for_stream(second.id) == nil
    series_id = Repo.get!(Season, first.season_id).series_id
    series = Iptv.get_series_with_seasons!(series_id)
    refute Enum.any?(hd(series.seasons).episodes, &(&1.id == second.id))
  end

  test "new payload data clears a dead marker, unchanged sync preserves it" do
    provider = global_provider_fixture()
    movie = movie_fixture(provider)
    await_mark(:movie, movie.id, provider.id, {:unexpected_status, 404})

    query =
      EnrichmentFields.conflict_update(Movie, [:name, :updated_at], "movie")

    now = DateTime.utc_now(:second)

    attrs = %{
      catalog_item_id: movie.catalog_item_id,
      stream_id: movie.stream_id,
      provider_id: provider.id,
      name: movie.name,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(Movie, [attrs],
      on_conflict: query,
      conflict_target: [:provider_id, :stream_id]
    )

    assert Repo.get!(Movie, movie.id).dead_since

    Repo.insert_all(Movie, [Map.put(attrs, :name, "File replaced")],
      on_conflict: query,
      conflict_target: [:provider_id, :stream_id]
    )

    refute Repo.get!(Movie, movie.id).dead_since
  end

  defp await_mark(type, id, provider_id, reason) do
    assert {:ok, pid} = Iptv.record_vod_failure(type, id, provider_id, reason)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp episode_fixture(provider) do
    series = series_content_fixture(provider)
    season = Repo.insert!(%Season{series_id: series.id, season_number: 1})
    episode_in_season(season.id, provider.id, 1)
  end

  defp episode_in_season(season_id, provider_id, number) do
    item = catalog_item_fixture("episode", provider_id)

    Repo.insert!(%Episode{
      season_id: season_id,
      catalog_item_id: item.id,
      episode_id: System.unique_integer([:positive]),
      episode_num: number,
      title: "Episode #{number}",
      container_extension: "mp4"
    })
  end
end
