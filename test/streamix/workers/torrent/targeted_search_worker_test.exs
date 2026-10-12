defmodule Streamix.Workers.Torrent.TargetedSearchWorkerTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv.{Movie, Provider}
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentScraperStub, as: Stub
  alias Streamix.TestSupport.{TorrentSearchSource, TorrentTestSource}
  alias Streamix.Torrent
  alias Streamix.Workers.Torrent.TargetedSearchWorker

  @gratis "https://gratistorrent.com"
  @search "#{@gratis}/index.php?busca=Matrix+Resurrections"

  @wanted_args [
    %{
      "tmdb_id" => "624860",
      "imdb_id" => "tt10838180",
      "year" => 2021,
      "title" => "Matrix Resurrections"
    }
  ]

  setup do
    previous_sources = Application.get_env(:streamix, :torrent_sources)
    previous_provider = Application.get_env(:streamix, :torrent_provider)
    Application.put_env(:streamix, :torrent_sources, [TorrentTestSource, TorrentSearchSource])

    on_exit(fn ->
      restore(:torrent_sources, previous_sources)
      restore(:torrent_provider, previous_provider)
    end)

    :ok
  end

  describe "perform/1" do
    test "searches, ingests matches and checkpoints the position" do
      provider = torrent_provider_fixture()

      Stub.route(%{
        @search => Stub.html("gratis_search.html"),
        "#{@gratis}/matrix-resurrections-download-torrent/" => Stub.html("gratis_post.html")
      })

      job =
        %{"provider_id" => provider.id, "source_slug" => "searchable", "wanted" => @wanted_args}
        |> TargetedSearchWorker.new()
        |> Oban.insert!()

      assert :ok = TargetedSearchWorker.perform(job)

      assert %Movie{tmdb_id: "624860"} = Repo.get_by!(Movie, provider_id: provider.id)
      meta = Repo.get!(Oban.Job, job.id).meta
      assert meta["next_index"] == 1
      assert meta["matched"] == 1
    end

    test "resumes from the checkpoint instead of searching again" do
      provider = torrent_provider_fixture()
      Stub.route(%{})

      job =
        %{"provider_id" => provider.id, "source_slug" => "searchable", "wanted" => @wanted_args}
        |> TargetedSearchWorker.new()
        |> Oban.insert!()

      assert :ok = TargetedSearchWorker.perform(%{job | meta: %{"next_index" => 1}})
      assert Stub.requested_urls() == []
    end

    test "retries later when the site keeps answering 429" do
      provider = torrent_provider_fixture()
      Stub.route(%{@search => {429, [{"retry-after", "0"}], "slow down"}})

      assert {:error, {:rate_limited, _details}} =
               perform_job(TargetedSearchWorker, %{
                 "provider_id" => provider.id,
                 "source_slug" => "searchable",
                 "wanted" => @wanted_args
               })

      assert TargetedSearchWorker.backoff(%Oban.Job{attempt: 2}) == 1_800
    end

    test "cancels a layout change instead of retrying it" do
      provider = torrent_provider_fixture()
      broken = "<html><body>novo layout</body></html>"

      Stub.route(%{
        @search => broken,
        "https://brutotorrent.com/index.php?busca=Matrix+Resurrections" => broken,
        "https://apachetorrents.com/index.php?busca=Matrix+Resurrections" => broken
      })

      assert {:cancel, {:layout_changed, _details}} =
               perform_job(TargetedSearchWorker, %{
                 "provider_id" => provider.id,
                 "source_slug" => "searchable",
                 "wanted" => @wanted_args
               })
    end

    test "cancels a switched-off source" do
      provider = torrent_provider_fixture()

      Application.put_env(:streamix, :torrent_sources, [
        Streamix.Torrent.Sources.ComandoTorrent
      ])

      assert {:cancel, :source_disabled} =
               perform_job(TargetedSearchWorker, %{
                 "provider_id" => provider.id,
                 "source_slug" => "comandotorrent",
                 "wanted" => @wanted_args
               })
    end

    test "cancels unknown sources, missing providers and invalid wanted lists" do
      provider = torrent_provider_fixture()

      args = %{
        "provider_id" => provider.id,
        "source_slug" => "searchable",
        "wanted" => @wanted_args
      }

      assert {:cancel, :unknown_source} =
               perform_job(TargetedSearchWorker, %{args | "source_slug" => "nope"})

      assert {:cancel, :provider_not_found} =
               perform_job(TargetedSearchWorker, %{args | "provider_id" => 0})

      assert {:cancel, {:invalid_wanted, 0, :invalid_tmdb_id}} =
               perform_job(TargetedSearchWorker, %{args | "wanted" => [%{"title" => "x"}]})
    end
  end

  describe "Streamix.Torrent.enqueue_targeted_search/2" do
    test "enqueues one job per searchable source for the system provider" do
      Application.put_env(:streamix, :torrent_provider, enabled: true)

      assert {:ok, [job]} =
               Torrent.enqueue_targeted_search([
                 %{
                   tmdb_id: 624_860,
                   imdb_id: "tt10838180",
                   year: 2021,
                   title: "Matrix Resurrections"
                 }
               ])

      assert job.args["source_slug"] == "searchable"
      assert [%{"tmdb_id" => "624860", "imdb_id" => "tt10838180"}] = job.args["wanted"]
      assert_enqueued(worker: TargetedSearchWorker, args: %{"source_slug" => "searchable"})
    end

    test "refuses while the torrent provider is disabled" do
      Application.put_env(:streamix, :torrent_provider, enabled: false)

      assert {:error, :torrent_disabled} =
               Torrent.enqueue_targeted_search([%{tmdb_id: 1, title: "X"}])
    end

    test "rejects an invalid wanted list before touching the queue" do
      assert {:error, {:invalid_wanted, 0, :missing_title}} =
               Torrent.enqueue_targeted_search([%{tmdb_id: 1}])
    end
  end

  defp torrent_provider_fixture do
    %Provider{}
    |> Provider.changeset(%{
      name: "Torrent Aggregator (test)",
      url: "torrent://aggregator-test-#{System.unique_integer([:positive])}",
      provider_type: :torrent,
      is_system: true,
      visibility: :global,
      is_active: true
    })
    |> Repo.insert!()
  end

  defp restore(key, nil), do: Application.delete_env(:streamix, key)
  defp restore(key, value), do: Application.put_env(:streamix, key, value)
end
