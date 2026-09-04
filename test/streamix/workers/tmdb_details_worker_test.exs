defmodule Streamix.Workers.TmdbDetailsWorkerTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Movie, Series}
  alias Streamix.Repo
  alias Streamix.Workers.TmdbDetailsWorker

  # The worker drives the real enrichment path. With TMDB switched off it runs
  # end to end and writes nothing, which is exactly the case these tests care
  # about: what the bookkeeping does when the upstream has no answer.
  setup do
    previous = Application.get_env(:streamix, :tmdb)
    Application.put_env(:streamix, :tmdb, enabled: false)

    on_exit(fn ->
      if previous do
        Application.put_env(:streamix, :tmdb, previous)
      else
        Application.delete_env(:streamix, :tmdb)
      end
    end)

    # gindex providers carry no credentials, so enrichment skips the Xtream
    # leg and this suite never reaches for the network.
    provider = global_provider_fixture(%{provider_type: :gindex})
    %{provider: provider}
  end

  describe "enqueue_pending/1" do
    test "picks matched rows that were never read, and nothing else", %{provider: provider} do
      pending = movie_fixture(provider, %{tmdb_id: "550", plot: nil})
      blank_plot = movie_fixture(provider, %{tmdb_id: "551", plot: ""})

      _no_match = movie_fixture(provider, %{tmdb_id: nil, plot: nil})
      _already_written = movie_fixture(provider, %{tmdb_id: "552", plot: "Já tem sinopse."})
      _already_read = stamp(movie_fixture(provider, %{tmdb_id: "553", plot: nil}))

      assert %{movie: %{rows: 2}} = TmdbDetailsWorker.enqueue_pending()

      assert enqueued_ids("movie") == Enum.sort([pending.id, blank_plot.id])
    end

    test "picks a row whose plot is set but whose title is blank", %{provider: provider} do
      # A blank title is displayed as the raw `name`, so it is just as much a
      # gap as a missing synopsis.
      untitled =
        movie_fixture(provider, %{tmdb_id: "554", plot: "Tem sinopse.", title: nil})

      _complete =
        movie_fixture(provider, %{tmdb_id: "555", plot: "Tem sinopse.", title: "Tem título"})

      assert %{movie: %{rows: 1}} = TmdbDetailsWorker.enqueue_pending()
      assert enqueued_ids("movie") == [untitled.id]
    end

    test "returns matched series the same way", %{provider: provider} do
      series = series_content_fixture(provider, %{tmdb_id: "1399", plot: nil})
      _skipped = series_content_fixture(provider, %{tmdb_id: nil, plot: nil})

      assert %{series: %{rows: 1, batches: 1}} = TmdbDetailsWorker.enqueue_pending()
      assert enqueued_ids("series") == [series.id]
    end

    test "brings back a stale row whose plot is still empty", %{provider: provider} do
      recent = movie_fixture(provider, %{tmdb_id: "600", plot: nil})
      stale = movie_fixture(provider, %{tmdb_id: "601", plot: nil})

      stamp(recent, DateTime.add(DateTime.utc_now(:second), -1, :day))
      stamp(stale, DateTime.add(DateTime.utc_now(:second), -45, :day))

      assert %{movie: %{rows: 1}} = TmdbDetailsWorker.enqueue_pending()
      assert enqueued_ids("movie") == [stale.id]
    end

    test "leaves a stale row alone once it has a plot", %{provider: provider} do
      enriched = movie_fixture(provider, %{tmdb_id: "602", plot: "Uma sinopse."})
      stamp(enriched, DateTime.add(DateTime.utc_now(:second), -45, :day))

      assert %{movie: %{rows: 0, batches: 0}} = TmdbDetailsWorker.enqueue_pending()
      assert enqueued_ids("movie") == []
    end

    test "spreads batches over time instead of dumping them at once", %{provider: provider} do
      for n <- 1..5, do: movie_fixture(provider, %{tmdb_id: "70#{n}", plot: nil})

      assert %{movie: %{batches: 3}} = TmdbDetailsWorker.enqueue_pending(batch_size: 2, delay: 30)

      scheduled = Enum.map(jobs_for("movie"), & &1.scheduled_at)
      assert length(Enum.uniq(scheduled)) == 3
    end
  end

  describe "perform/1 batch mode" do
    test "stamps rows TMDB had no answer for so they are not re-picked", %{provider: provider} do
      movie = movie_fixture(provider, %{tmdb_id: "550", plot: nil})

      assert :ok =
               TmdbDetailsWorker.perform(%Oban.Job{
                 args: %{"kind" => "movie", "ids" => [movie.id]}
               })

      assert %Movie{tmdb_details_at: %DateTime{}, plot: nil} = Repo.get!(Movie, movie.id)

      # The stamp is the whole point: a second cron run must not queue it again.
      assert %{movie: %{rows: 0}} = TmdbDetailsWorker.enqueue_pending()
    end

    test "stamps series the same way", %{provider: provider} do
      series = series_content_fixture(provider, %{tmdb_id: "1399", plot: nil})

      assert :ok =
               TmdbDetailsWorker.perform(%Oban.Job{
                 args: %{"kind" => "series", "ids" => [series.id]}
               })

      assert %Series{tmdb_details_at: %DateTime{}} = Repo.get!(Series, series.id)
    end

    test "tolerates ids that no longer exist", %{provider: provider} do
      movie = movie_fixture(provider, %{tmdb_id: "550", plot: nil})
      Repo.delete!(movie)

      assert :ok =
               TmdbDetailsWorker.perform(%Oban.Job{
                 args: %{"kind" => "movie", "ids" => [movie.id]}
               })
    end
  end

  test "uses a bounded timeout below the Lifeline threshold" do
    assert TmdbDetailsWorker.timeout(%Oban.Job{}) == :timer.minutes(15)
  end

  defp stamp(row, at \\ DateTime.utc_now(:second)) do
    schema = row.__struct__

    Repo.update_all(
      from(r in schema, where: r.id == ^row.id),
      set: [tmdb_details_at: at]
    )

    row
  end

  defp jobs_for(kind) do
    Repo.all(from(j in Oban.Job, where: fragment("?->>'kind' = ?", j.args, ^kind)))
  end

  defp enqueued_ids(kind) do
    kind
    |> jobs_for()
    |> Enum.flat_map(& &1.args["ids"])
    |> Enum.sort()
  end
end
