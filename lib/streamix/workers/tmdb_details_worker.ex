defmodule Streamix.Workers.TmdbDetailsWorker do
  @moduledoc """
  Reads TMDB *details* for catalog rows that already carry a `tmdb_id`.

  The expensive half of the work — matching a filename to a TMDB record — is
  already done for most of the catalog, but nothing ever consumed the result.
  `Streamix.Workers.Gindex.BackfillTmdbWorker` resolves a `tmdb_id`, writes the
  poster, stamps `tmdb_searched_at`, and stops there. That is why ~14.5k movies
  and ~1.7k series hold a `tmdb_id` and render with no synopsis: the details
  endpoint was never called for them.

  Enrichment itself is not reimplemented here. Each row goes through
  `Streamix.Catalog.fetch_movie_info/1` / `fetch_series_info/1`, the same path a
  detail page takes when someone opens it, so a row gets exactly what a visitor
  would have triggered: plot, rating, tagline, content rating, trailer, runtime,
  poster and the backdrop/still galleries — from one cached TMDB request, on the
  per-row TMDB profile (`:gindex` rows keep their own token pool and pacer).
  This worker only decides *which* rows go through it, and when.

  Runs in three shapes:

    * **Batch mode** — args `%{"kind" => "movie|series", "ids" => [...]}`.
    * **Cron mode** — args `%{}`. Picks up to `@cron_limit` pending rows per
      kind, plus a slice of stale retries, and spreads them across batches.
    * **Manual** — `enqueue_pending(limit: 5_000)` from IEx to drain faster
      than the nightly cadence.

  `tmdb_details_at` is what makes this idempotent. "Plot is still empty" cannot
  serve as the marker on its own: TMDB has no pt-BR overview for a long tail of
  titles, and those rows would be re-fetched every single night forever. A row
  is stamped once its enrichment ran to completion, and only rows stamped more
  than `@stale_retry_after_days` ago that *still* have no plot come back — which
  covers a transient TMDB failure without turning the tail into a treadmill.
  """

  use Oban.Worker,
    queue: :tmdb_details,
    max_attempts: 3,
    priority: 3

  import Ecto.Query

  alias Streamix.Catalog
  alias Streamix.Iptv.{Movie, Series}
  alias Streamix.Repo

  require Logger

  @cron_limit 3_000
  @batch_size 25
  # Each `fetch_info` can issue up to ~2 upstream calls. Two in flight per
  # batch, against a queue of 2, peaks at 4 — well inside the TMDB ceiling and
  # inside what the gindex pacer hands out.
  @max_concurrency 2
  @batch_timeout :timer.seconds(45)
  # Seconds between scheduled batches, so a cron run drains steadily instead of
  # dumping every batch onto the queue at once.
  @batch_delay 15
  @stale_retry_after_days 30
  # Retries are capped well below the fresh backlog: draining rows that never
  # had a chance matters more than re-asking about the ones that did.
  @stale_retry_limit 250

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "movie", "ids" => ids}}) when is_list(ids) do
    Movie
    |> load_batch(ids, [:provider, :assets, :credits])
    |> run_batch(Movie, :movie, &Catalog.fetch_movie_info/1)
  end

  def perform(%Oban.Job{args: %{"kind" => "series", "ids" => ids}}) when is_list(ids) do
    Series
    |> load_batch(ids, [:assets, credits: :person])
    |> run_batch(Series, :series, &Catalog.fetch_series_info/1)
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    summary = enqueue_pending()
    Logger.info("[TMDB Details] cron enqueued #{inspect(summary)}")
    :ok
  end

  @doc """
  Enqueues pending rows for both kinds and returns what was scheduled.

  ## Options

    * `:limit` — maximum fresh rows per kind (default: `#{@cron_limit}`)
    * `:batch_size` — ids per job (default: `#{@batch_size}`)
    * `:delay` — seconds between batches (default: `#{@batch_delay}`)
  """
  @spec enqueue_pending(keyword()) :: map()
  def enqueue_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, @cron_limit)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    delay = Keyword.get(opts, :delay, @batch_delay)

    Map.new([{Movie, :movie}, {Series, :series}], fn {schema, kind} ->
      ids = Enum.uniq(pending_ids(schema, limit) ++ stale_ids(schema))
      batches = enqueue_batches(Atom.to_string(kind), ids, batch_size, delay)

      {kind, %{rows: length(ids), batches: batches}}
    end)
  end

  # --- Batch processing ---

  defp load_batch(schema, ids, preloads) do
    Repo.all(from(r in schema, where: r.id in ^ids, preload: ^preloads))
  end

  defp run_batch(rows, schema, kind, fetch_fun) do
    {enriched, failed} =
      rows
      |> Task.async_stream(&enrich(&1, schema, fetch_fun),
        max_concurrency: @max_concurrency,
        timeout: @batch_timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, :enriched}, {enriched, failed} -> {enriched + 1, failed}
        {:ok, :empty}, {enriched, failed} -> {enriched, failed}
        {:exit, _reason}, {enriched, failed} -> {enriched, failed + 1}
      end)

    Logger.info(
      "[TMDB Details] #{kind} batch=#{length(rows)} enriched=#{enriched} failed=#{failed}"
    )

    :ok
  end

  # The stamp goes on whether or not TMDB had an overview — an absent pt-BR
  # translation is an answer, and re-asking nightly is the behaviour this
  # column exists to prevent. A crash or timeout leaves the row unstamped, so
  # it is picked up again on the next pass.
  defp enrich(row, schema, fetch_fun) do
    result = fetch_fun.(row)
    stamp_details_at(schema, row.id)

    case result do
      {:ok, %{plot: plot}} when is_binary(plot) and plot != "" -> :enriched
      _ -> :empty
    end
  end

  defp stamp_details_at(schema, id) do
    from(r in schema, where: r.id == ^id)
    |> Repo.update_all(set: [tmdb_details_at: DateTime.utc_now(:second)])
  end

  # --- Selection ---

  # Rows that were matched but never read. `order_by: :id` keeps successive
  # runs walking forward through the catalog instead of re-picking the same
  # head when a batch fails.
  defp pending_ids(schema, limit) do
    Repo.all(
      from(r in schema,
        where: is_nil(r.tmdb_details_at),
        where: not is_nil(r.tmdb_id) and r.tmdb_id != "",
        where: is_nil(r.plot) or r.plot == "",
        order_by: [asc: r.id],
        limit: ^limit,
        select: r.id
      )
    )
  end

  defp stale_ids(schema) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@stale_retry_after_days, :day)

    Repo.all(
      from(r in schema,
        where: r.tmdb_details_at < ^cutoff,
        where: not is_nil(r.tmdb_id) and r.tmdb_id != "",
        where: is_nil(r.plot) or r.plot == "",
        order_by: [asc: r.tmdb_details_at],
        limit: ^@stale_retry_limit,
        select: r.id
      )
    )
  end

  defp enqueue_batches(_kind, [], _batch_size, _delay), do: 0

  defp enqueue_batches(kind, ids, batch_size, delay) do
    ids
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {chunk, index}, acc ->
      scheduled_at = DateTime.add(DateTime.utc_now(), index * delay, :second)

      case %{"kind" => kind, "ids" => chunk}
           |> __MODULE__.new(scheduled_at: scheduled_at)
           |> Oban.insert() do
        {:ok, _job} -> acc + 1
        {:error, _reason} -> acc
      end
    end)
  end
end
