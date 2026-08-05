defmodule Streamix.Torrent.SyncTest do
  use Streamix.DataCase, async: false

  alias Streamix.Iptv.{Movie, Provider}
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentTestSource
  alias Streamix.Torrent.{Sync, TorrentStream}

  setup do
    previous_sources = Application.get_env(:streamix, :torrent_sources)

    Application.put_env(:streamix, :torrent_sources, [TorrentTestSource])

    on_exit(fn ->
      if previous_sources do
        Application.put_env(:streamix, :torrent_sources, previous_sources)
      else
        Application.delete_env(:streamix, :torrent_sources)
      end

      Application.delete_env(:streamix, :torrent_test_source)
      Application.delete_env(:streamix, :torrent_second_source_items)
    end)

    {:ok, provider: torrent_provider_fixture()}
  end

  describe "sync_provider/1" do
    test "rejects non-torrent providers" do
      provider = %Provider{provider_type: :gindex, id: 1, name: "fake"}
      assert {:error, :not_torrent_provider} = Sync.sync_provider(provider)
    end

    test "syncs movies and torrent_streams from a stub source", %{provider: provider} do
      seed_pages([
        {1,
         [
           sample_item("ext-1", "Movie One", [magnet("a")]),
           sample_item("ext-2", "Movie Two", [magnet("b"), magnet("c")])
         ], %{next_page: nil}}
      ])

      assert {:ok, stats} = Sync.sync_provider(provider)
      assert stats.movies_count == 2
      assert [%{slug: "test", status: :ok, movies: 2, torrents: 3}] = stats.sources

      movies = Repo.all(Movie) |> Enum.filter(&(&1.provider_id == provider.id))
      assert length(movies) == 2
      assert Enum.all?(movies, & &1.catalog_item_id)

      streams = Repo.all(TorrentStream)
      assert length(streams) == 3
      assert Enum.all?(streams, &(&1.source_slug == "test"))
      assert Enum.all?(streams, & &1.movie_id)

      updated = Repo.get!(Provider, provider.id)
      assert updated.sync_status == "completed"
      assert updated.movies_count == 2
      assert updated.vod_synced_at
    end

    test "is idempotent — running the same items twice doesn't duplicate", %{provider: provider} do
      seed_pages([
        {1, [sample_item("ext-9", "Idempotent", [magnet("d")])], %{next_page: nil}}
      ])

      assert {:ok, _} = Sync.sync_provider(provider)
      assert {:ok, _} = Sync.sync_provider(provider)

      movies = Repo.all(Movie) |> Enum.filter(&(&1.provider_id == provider.id))
      assert length(movies) == 1

      streams = Repo.all(TorrentStream)
      assert length(streams) == 1
    end

    test "keeps the first source owner when a later source repeats the info_hash", %{
      provider: provider
    } do
      hash_seed = "shared-release"

      seed_pages([
        {1, [sample_item("first-movie", "First Movie", [magnet(hash_seed)])], %{next_page: nil}}
      ])

      assert {:ok, _} = Sync.sync_source(provider, TorrentTestSource)

      first_stream = Repo.one!(TorrentStream)
      first_movie_id = first_stream.movie_id
      assert first_stream.source_slug == "test"

      second_magnet =
        hash_seed
        |> magnet()
        |> Map.merge(%{source_slug: "second", seeders: 99})

      Application.put_env(:streamix, :torrent_second_source_items, [
        sample_item("second-movie", "Second Movie", [second_magnet])
      ])

      assert {:ok, _} = Sync.sync_source(provider, __MODULE__.SecondSource)

      stream = Repo.one!(TorrentStream)
      assert stream.source_slug == "test"
      assert stream.movie_id == first_movie_id
      assert stream.seeders == 99
    end

    test "follows pagination until next_page is nil", %{provider: provider} do
      seed_pages([
        {1, [sample_item("p1", "Page1", [magnet("aa")])], %{next_page: 2}},
        {2, [sample_item("p2", "Page2", [magnet("bb")])], %{next_page: 3}},
        {3, [sample_item("p3", "Page3", [magnet("cc")])], %{next_page: nil}}
      ])

      assert {:ok, stats} = Sync.sync_provider(provider)
      assert stats.movies_count == 3
    end

    test "skips invalid info_hashes without aborting the whole batch", %{provider: provider} do
      bad_magnet = %{
        info_hash: "not-a-hash",
        magnet_uri: "magnet:?xt=urn:btih:not-a-hash",
        source_slug: "test"
      }

      seed_pages([
        {1,
         [
           sample_item("good", "Good", [magnet("aa")]),
           sample_item("bad", "Bad", [bad_magnet])
         ], %{next_page: nil}}
      ])

      assert {:ok, _stats} = Sync.sync_provider(provider)

      streams = Repo.all(TorrentStream)
      assert length(streams) == 1
      assert hd(streams).info_hash |> byte_size() == 40
    end
  end

  describe "sync_source/2" do
    test "returns {:ok, stats} for a torrent provider", %{provider: provider} do
      seed_pages([
        {1, [sample_item("ext-x", "Solo", [magnet("ee")])], %{next_page: nil}}
      ])

      assert {:ok, %{movies: 1, torrents: 1}} = Sync.sync_source(provider, TorrentTestSource)
    end

    test "rejects non-torrent providers" do
      provider = %Provider{provider_type: :xtream, id: 99, name: "xt"}
      assert {:error, :not_torrent_provider} = Sync.sync_source(provider, TorrentTestSource)
    end

    test "propagates source errors", %{provider: provider} do
      defmodule FailingSource do
        @behaviour Streamix.Torrent.Source
        @impl true
        def slug, do: "failing"
        @impl true
        def name, do: "Failing"
        @impl true
        def rate_limit_ms, do: 1
        @impl true
        def fetch_listing(_opts), do: {:error, :boom}
      end

      assert {:error, :boom} = Sync.sync_source(provider, FailingSource)
    end

    test "fails the page when an item cannot be persisted", %{provider: provider} do
      seed_pages([
        {1, [sample_item("orphan", "Orphan Movie", [magnet("orphan")])], %{next_page: nil}}
      ])

      Repo.delete!(provider)

      assert {:error, {:item_upsert_failed, "orphan", _reason}} =
               Sync.sync_source(provider, TorrentTestSource)

      assert Repo.aggregate(Movie, :count) == 0
      assert Repo.aggregate(TorrentStream, :count) == 0
    end

    test "resumes from a persisted page and reports the next checkpoint", %{
      provider: provider
    } do
      seed_pages([
        {1, [sample_item("old", "Already Indexed", [magnet("old")])], %{next_page: 2}},
        {2, [sample_item("new", "Resumed Movie", [magnet("new")])], %{next_page: nil}}
      ])

      test_pid = self()

      assert {:ok, %{movies: 1, torrents: 1}} =
               Sync.sync_source(provider, TorrentTestSource,
                 start_page: 2,
                 on_page: fn progress ->
                   send(test_pid, {:checkpoint, progress})
                   :ok
                 end
               )

      assert_receive {:checkpoint, %{page: 2, next_page: nil, movies: 1, torrents: 1}}

      assert [movie] = Repo.all(Movie)
      assert movie.title == "Resumed Movie"
    end

    test "returns an error instead of reporting success at the page safety limit", %{
      provider: provider
    } do
      seed_pages([
        {1, [sample_item("p1", "Page 1", [magnet("limit")])], %{next_page: 2}}
      ])

      assert {:error, {:page_limit_exceeded, %{source: "test", page: 2, max_pages: 1}}} =
               Sync.sync_source(provider, TorrentTestSource, max_pages: 1)
    end

    test "rejects non-monotonic pagination cursors", %{provider: provider} do
      seed_pages([
        {1, [sample_item("p1", "Page 1", [magnet("loop")])], %{next_page: 1}}
      ])

      assert {:error, {:invalid_pagination, %{source: "test", page: 1, next_page: 1}}} =
               Sync.sync_source(provider, TorrentTestSource)
    end
  end

  describe "refresh_provider_counts/1" do
    test "recomputes movies_count from the DB and marks completed", %{provider: provider} do
      seed_pages([
        {1,
         [
           sample_item("ext-1", "Movie One", [magnet("a")]),
           sample_item("ext-2", "Movie Two", [magnet("b")])
         ], %{next_page: nil}}
      ])

      {:ok, _stats} = Sync.sync_source(provider, TorrentTestSource)

      # Simulate the stale state the per-source fan-out used to leave.
      provider
      |> Provider.sync_changeset(%{sync_status: "failed", movies_count: 0})
      |> Repo.update!()

      {:ok, refreshed} = Sync.refresh_provider_counts(Repo.reload!(provider))

      assert refreshed.movies_count == 2
      assert refreshed.sync_status == "completed"
      assert refreshed.vod_synced_at
    end

    test "rejects non-torrent providers" do
      assert {:error, :not_torrent_provider} =
               Sync.refresh_provider_counts(%Provider{provider_type: :xtream, id: 1})
    end
  end

  # Helpers

  defp seed_pages(pages), do: Application.put_env(:streamix, :torrent_test_source, pages)

  defp sample_item(external_id, title, torrents) do
    %{
      external_id: external_id,
      title: title,
      year: 2024,
      imdb_id: nil,
      tmdb_id: nil,
      poster_url: nil,
      backdrop_url: nil,
      plot: nil,
      rating: 7.5,
      runtime_minutes: 100,
      genres: [],
      torrents: torrents
    }
  end

  defp magnet(seed) when is_binary(seed) do
    info_hash = pad_hash(seed)

    %{
      info_hash: info_hash,
      magnet_uri: "magnet:?xt=urn:btih:#{info_hash}",
      source_slug: "test",
      quality: "1080p",
      codec: "x264",
      audio_track: "5.1",
      container: "mp4",
      size_bytes: 1_000_000,
      seeders: 5,
      leechers: 1
    }
  end

  defp pad_hash(seed) do
    raw = :erlang.phash2(seed) |> Integer.to_string(16) |> String.downcase()
    String.pad_trailing(raw, 40, "0") |> String.slice(0, 40)
  end

  defp torrent_provider_fixture do
    {:ok, provider} =
      %Provider{}
      |> Provider.changeset(%{
        name: "Torrent Aggregator (test)",
        url: "torrent://aggregator-test-#{System.unique_integer([:positive])}",
        provider_type: :torrent,
        is_system: true,
        visibility: :global,
        is_active: true
      })
      |> Repo.insert()

    provider
  end

  defmodule SecondSource do
    @behaviour Streamix.Torrent.Source

    @impl true
    def slug, do: "second"

    @impl true
    def name, do: "Second"

    @impl true
    def rate_limit_ms, do: 1

    @impl true
    def fetch_listing(_opts) do
      {:ok, Application.get_env(:streamix, :torrent_second_source_items, []), %{next_page: nil}}
    end
  end
end
