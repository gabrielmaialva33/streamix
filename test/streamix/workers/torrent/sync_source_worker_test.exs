defmodule Streamix.Workers.Torrent.SyncSourceWorkerTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv.Provider
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentTestSource
  alias Streamix.Torrent.TorrentStream
  alias Streamix.Workers.Torrent.SyncSourceWorker

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
    end)

    :ok
  end

  describe "perform/1" do
    test "returns :ok and persists torrents for a known source" do
      provider = torrent_provider_fixture()

      Application.put_env(:streamix, :torrent_test_source, [
        {1,
         [
           %{
             external_id: "w-1",
             title: "Worker Movie",
             torrents: [
               %{
                 info_hash: pad("aa"),
                 magnet_uri: "magnet:?xt=urn:btih:#{pad("aa")}",
                 source_slug: "test",
                 quality: "1080p",
                 codec: "x264",
                 audio_track: "5.1",
                 size_bytes: 1_000_000,
                 seeders: 1,
                 leechers: 0
               }
             ]
           }
         ], %{next_page: nil}}
      ])

      assert :ok =
               perform_job(SyncSourceWorker, %{
                 "provider_id" => provider.id,
                 "source_slug" => "test"
               })

      assert [%TorrentStream{source_slug: "test"}] = Repo.all(TorrentStream)
    end

    test "returns {:error, :provider_not_found} for missing provider" do
      assert {:error, :provider_not_found} =
               perform_job(SyncSourceWorker, %{
                 "provider_id" => 0,
                 "source_slug" => "test"
               })
    end

    test "returns {:error, :unknown_source} for unknown slug" do
      provider = torrent_provider_fixture()

      assert {:error, :unknown_source} =
               perform_job(SyncSourceWorker, %{
                 "provider_id" => provider.id,
                 "source_slug" => "does-not-exist"
               })
    end

    test "persists the next page and resumes on retry" do
      provider = torrent_provider_fixture()

      Application.put_env(:streamix, :torrent_test_source, [
        {1, [item("first", "First")], %{next_page: 2}},
        {2, [item("second", "Second")], %{next_page: nil}}
      ])

      job =
        %{
          "provider_id" => provider.id,
          "source_slug" => "test",
          "workflow_id" => Ecto.UUID.generate()
        }
        |> SyncSourceWorker.new()
        |> Oban.insert!()

      assert :ok = SyncSourceWorker.perform(job)

      checkpoint = Repo.get!(Oban.Job, job.id).meta
      assert checkpoint["last_page"] == 2
      assert checkpoint["next_page"] == nil
      assert checkpoint["movies_processed"] == 2
      assert checkpoint["torrents_processed"] == 2

      resumed =
        %{job | meta: Map.put(checkpoint, "next_page", 2)}

      assert :ok = SyncSourceWorker.perform(resumed)
      assert Repo.aggregate(TorrentStream, :count) == 2
    end
  end

  describe "configuration" do
    test "uses the torrent_sync queue and 3 max attempts" do
      job =
        SyncSourceWorker.new(%{"provider_id" => 1, "source_slug" => "test"})

      changeset = job
      assert changeset.changes.queue == "torrent_sync"
      assert changeset.changes.max_attempts == 3
    end

    test "allows a full source walk but stays below the Lifeline threshold" do
      assert SyncSourceWorker.timeout(%Oban.Job{}) == :timer.minutes(150)
    end
  end

  defp pad(seed) do
    raw = :erlang.phash2(seed) |> Integer.to_string(16) |> String.downcase()
    String.pad_trailing(raw, 40, "0") |> String.slice(0, 40)
  end

  defp item(external_id, title) do
    hash = pad(external_id)

    %{
      external_id: external_id,
      title: title,
      year: 2026,
      imdb_id: nil,
      tmdb_id: nil,
      poster_url: nil,
      backdrop_url: nil,
      plot: nil,
      rating: 7.0,
      runtime_minutes: 90,
      genres: [],
      torrents: [
        %{
          info_hash: hash,
          magnet_uri: "magnet:?xt=urn:btih:#{hash}",
          source_slug: "test",
          quality: "1080p",
          codec: "x264",
          audio_track: "2.0",
          size_bytes: 1_000_000,
          seeders: 1,
          leechers: 0
        }
      ]
    }
  end

  defp torrent_provider_fixture do
    {:ok, provider} =
      Repo.insert(%Provider{
        name: "Torrent Aggregator (test)",
        url: "https://torrent-aggregator-test-#{System.unique_integer([:positive])}.example.com",
        username: "system",
        password: "system",
        provider_type: :torrent,
        is_system: true,
        visibility: :global,
        is_active: true
      })

    provider
  end
end
