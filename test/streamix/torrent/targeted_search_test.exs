defmodule Streamix.Torrent.TargetedSearchTest do
  use Streamix.DataCase, async: false

  alias Streamix.Iptv.{Movie, Provider}
  alias Streamix.Repo
  alias Streamix.TestSupport.TorrentScraperStub, as: Stub
  alias Streamix.TestSupport.{TorrentSearchSource, TorrentTestSource}
  alias Streamix.Torrent.{TargetedSearch, TorrentStream}

  @gratis "https://gratistorrent.com"
  @search "#{@gratis}/index.php?busca=Matrix+Resurrections"
  @post "#{@gratis}/matrix-resurrections-download-torrent/"
  @legendado_post "#{@gratis}/matrix-resurrections-legendado-download-torrent/"

  @matrix %{
    tmdb_id: "624860",
    imdb_id: "tt10838180",
    year: 2021,
    title: "Matrix Resurrections",
    original_title: nil
  }

  setup do
    {:ok, provider: torrent_provider_fixture()}
  end

  defp route_matrix do
    Stub.route(%{
      @search => Stub.html("gratis_search.html"),
      @post => Stub.html("gratis_post.html"),
      @legendado_post => {404, "gone"}
    })
  end

  defp run(provider, wanted, opts \\ []) do
    TargetedSearch.run(
      provider,
      TorrentSearchSource,
      wanted,
      Keyword.put_new(opts, :rate_limit_backoff_ms, 0)
    )
  end

  describe "run/4 matching" do
    test "ingests the post whose IMDb id is the wanted one, stamped with the TMDB id", %{
      provider: provider
    } do
      route_matrix()

      assert {:ok, report} = run(provider, [@matrix])
      assert %{searched: 1, matched: 1, movies: 1, torrents: 5, next_index: 1} = report
      assert report.matched_tmdb_ids == ["624860"]

      movie = Repo.get_by!(Movie, provider_id: provider.id)
      assert movie.tmdb_id == "624860"
      assert movie.imdb_id == "tt10838180"
      assert movie.title == "Matrix Resurrections"
      assert movie.stream_id == :erlang.phash2(@post)

      streams = Repo.all(TorrentStream)
      assert length(streams) == 5
      assert Enum.all?(streams, &(&1.movie_id == movie.id))
      assert Enum.count(streams, &(&1.audio_track == "legendado")) == 2
    end

    test "falls back to title + year (±1) when the wanted movie has no IMDb id", %{
      provider: provider
    } do
      route_matrix()

      assert {:ok, %{matched: 1}} = run(provider, [%{@matrix | imdb_id: nil}])

      assert %Movie{tmdb_id: "624860", imdb_id: "tt10838180"} =
               Repo.get_by!(Movie, provider_id: provider.id)
    end

    test "a different IMDb id on the page is never ingested", %{provider: provider} do
      route_matrix()

      assert {:ok, %{matched: 0, no_match: 1, movies: 0}} =
               run(provider, [%{@matrix | imdb_id: "tt9999999"}])

      assert Repo.aggregate(Movie, :count) == 0
    end

    test "a year more than one off is not a title match", %{provider: provider} do
      route_matrix()

      assert {:ok, %{matched: 0}} = run(provider, [%{@matrix | imdb_id: nil, year: 2019}])
    end

    test "unsearchable titles cost no request", %{provider: provider} do
      Stub.route(%{})

      wanted = %{@matrix | title: "壹獄壹世界II：劫數難逃", imdb_id: nil}
      assert {:ok, %{unsearchable: 1}} = run(provider, [wanted])
      assert Stub.requested_urls() == []
    end
  end

  describe "run/4 stopping" do
    test "stops after repeated 429s and keeps the title for the next run", %{provider: provider} do
      throttled = {429, "slow down"}

      Stub.route(%{
        @search => throttled,
        "https://brutotorrent.com/index.php?busca=Matrix+Resurrections" => throttled,
        "https://apachetorrents.com/index.php?busca=Matrix+Resurrections" => throttled
      })

      assert {:error, {:rate_limited, _details}, report} =
               run(provider, [@matrix, %{@matrix | tmdb_id: "2"}])

      assert report.next_index == 0
      assert report.searched == 0

      # Three attempts of the first title (each trying every mirror), then stop.
      requested = Stub.requested_urls()
      assert length(requested) == 9
      assert Enum.count(requested, &(&1 == @search)) == 3
    end

    test "a throttled primary falls back to a sister mirror for the same title", %{
      provider: provider
    } do
      Stub.route(%{
        @search => {429, "slow down"},
        "https://brutotorrent.com/index.php?busca=Matrix+Resurrections" =>
          "<html><body><form role='search'><input name='busca'></form></body></html>"
      })

      assert {:ok, %{not_found: 1}} = run(provider, [@matrix])
    end

    test "halts at once when every mirror blocks the search", %{provider: provider} do
      challenge = Stub.cloudflare_challenge()

      Stub.route(%{
        @search => challenge,
        "https://brutotorrent.com/index.php?busca=Matrix+Resurrections" => challenge,
        "https://apachetorrents.com/index.php?busca=Matrix+Resurrections" => challenge
      })

      assert {:error, {:blocked, %{attempts: attempts}}, %{next_index: 0}} =
               run(provider, [@matrix, %{@matrix | tmdb_id: "2", title: "Outro Filme"}])

      assert length(attempts) == 3
      refute Enum.any?(Stub.requested_urls(), &String.contains?(&1, "Outro"))
    end

    test "resumes from start_index and reports progress after every title", %{
      provider: provider
    } do
      route_matrix()
      test_pid = self()
      skipped = %{@matrix | tmdb_id: "1", title: "Never Searched"}

      assert {:ok, %{next_index: 2, searched: 1}} =
               run(provider, [skipped, @matrix],
                 start_index: 1,
                 on_progress: fn report ->
                   send(test_pid, {:progress, report.next_index})
                   :ok
                 end
               )

      assert_received {:progress, 2}
      refute Enum.any?(Stub.requested_urls(), &String.contains?(&1, "Never"))
    end

    test "halts when the source is switched off instead of reporting misses", %{
      provider: provider
    } do
      # config/test.exs switches the real scrapers off.
      assert {:error, :source_disabled, %{next_index: 0, searched: 0}} =
               TargetedSearch.run(provider, Streamix.Torrent.Sources.ComandoTorrent, [@matrix])
    end

    test "rejects sources without search and non-torrent providers", %{provider: provider} do
      assert {:error, :search_not_supported, _report} =
               TargetedSearch.run(provider, TorrentTestSource, [@matrix])

      assert {:error, :not_torrent_provider, _report} =
               run(%Provider{provider_type: :xtream, id: 1}, [@matrix])
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
end
