defmodule Streamix.Workers.Torrent.SyncSourceWorkerTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv.Provider
  alias Streamix.Iptv.Torrent.TorrentStream
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentTestSource
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
  end

  describe "configuration" do
    test "uses the torrent_sync queue and 3 max attempts" do
      job =
        SyncSourceWorker.new(%{"provider_id" => 1, "source_slug" => "test"})

      changeset = job
      assert changeset.changes.queue == "torrent_sync"
      assert changeset.changes.max_attempts == 3
    end
  end

  defp pad(seed) do
    raw = :erlang.phash2(seed) |> Integer.to_string(16) |> String.downcase()
    String.pad_trailing(raw, 40, "0") |> String.slice(0, 40)
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
