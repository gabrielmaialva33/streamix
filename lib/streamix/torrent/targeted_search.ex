defmodule Streamix.Torrent.TargetedSearch do
  @moduledoc """
  Looks a list of wanted catalog movies up on one torrent source, instead
  of crawling thousands of listing pages hoping to meet them.

  For every `Streamix.Torrent.Wanted` entry, in order:

    1. the source searches its own site (`c:Streamix.Torrent.Source.search/2`),
       opening only the few posts whose snippet passes the title/year
       prefilter;
    2. `Streamix.Torrent.Matching.match/2` keeps the posts that are the wanted
       film (IMDb id first, then title + year ±1);
    3. matches are stamped with the wanted TMDB/IMDb ids and ingested through
       `Streamix.Torrent.Sync.ingest_items/3` — the same movie +
       `torrent_streams` upsert as the nightly crawl.

  Politeness lives in the scraper (≥1.5 s between requests per site). Here
  we only decide when to stop:

    * HTTP 429: back off (`Retry-After`, else `:rate_limit_backoff_ms`) and
      retry the same title; after `:max_rate_limits` consecutive 429s the
      run halts with `{:rate_limited, …}` so the job can resume later.
    * `:blocked` or `:layout_changed`: halt at once — every further request
      would fail the same way.
    * other errors: record the title as an error and move on; five in a row
      halt the run.

  The report's `next_index` is where a resumed run should start.
  """

  require Logger

  alias Streamix.Providers
  alias Streamix.Torrent.{Matching, Sync}
  alias Streamix.Torrent.Sources.HtmlScraper

  @default_max_rate_limits 3
  @default_rate_limit_backoff_ms :timer.seconds(60)
  @max_consecutive_errors 5

  @type report :: %{
          source: String.t(),
          total: non_neg_integer(),
          next_index: non_neg_integer(),
          searched: non_neg_integer(),
          matched: non_neg_integer(),
          no_match: non_neg_integer(),
          not_found: non_neg_integer(),
          unsearchable: non_neg_integer(),
          errors: non_neg_integer(),
          movies: non_neg_integer(),
          torrents: non_neg_integer(),
          matched_tmdb_ids: [String.t()]
        }

  @doc """
  Runs the targeted search of `wanted` on `source_module` for the torrent
  `provider`.

  Options:

    * `:start_index` — resume position (default 0).
    * `:on_progress` — `fn report -> :ok | {:error, term} end`, called after
      every title (checkpointing).
    * `:max_rate_limits` — consecutive 429s tolerated (default 3).
    * `:rate_limit_backoff_ms` — wait after a 429 without `Retry-After`
      (default 60 s).
  """
  @spec run(term(), module(), [map()], keyword()) ::
          {:ok, report()} | {:error, term(), report()}
  def run(provider, source_module, wanted, opts \\ []) when is_list(wanted) do
    start_index = Keyword.get(opts, :start_index, 0)
    report = new_report(source_module, length(wanted), start_index)

    cond do
      not searchable_source?(source_module) ->
        {:error, :search_not_supported, report}

      match?({:error, _}, Providers.torrent_sync_source(provider)) ->
        {:error, :not_torrent_provider, report}

      true ->
        ctx = %{
          provider: provider,
          source: source_module,
          on_progress: Keyword.get(opts, :on_progress, fn _report -> :ok end),
          max_rate_limits: Keyword.get(opts, :max_rate_limits, @default_max_rate_limits),
          backoff_ms: Keyword.get(opts, :rate_limit_backoff_ms, @default_rate_limit_backoff_ms),
          rate_limits: 0,
          errors: 0
        }

        Logger.info(
          "[Torrent TargetedSearch] #{report.source}: #{length(wanted) - start_index} title(s) " <>
            "from index #{start_index}"
        )

        wanted
        |> Enum.drop(start_index)
        |> loop(start_index, ctx, report)
        |> log_finish()
    end
  end

  @doc "Whether the source implements the optional `search/2` callback."
  @spec searchable_source?(module()) :: boolean()
  def searchable_source?(source_module) do
    Code.ensure_loaded?(source_module) and function_exported?(source_module, :search, 2)
  end

  defp loop([], index, _ctx, report), do: {:ok, %{report | next_index: index}}

  defp loop([wanted | rest] = remaining, index, ctx, report) do
    case search_one(ctx, wanted) do
      {:ok, outcome} ->
        report = record(report, wanted, outcome)
        continue(rest, index + 1, %{ctx | rate_limits: 0, errors: 0}, report)

      {:error, reason} ->
        handle_error(reason, remaining, index, ctx, report)
    end
  end

  defp handle_error(:source_disabled = reason, _remaining, index, _ctx, report),
    do: halt(reason, index, report)

  defp handle_error(reason, [wanted | rest] = remaining, index, ctx, report) do
    case HtmlScraper.failure_kind(reason) do
      :rate_limited ->
        rate_limits = ctx.rate_limits + 1

        if rate_limits >= ctx.max_rate_limits do
          halt(reason, index, report)
        else
          wait = backoff_ms(reason, ctx.backoff_ms)

          Logger.warning(
            "[Torrent TargetedSearch] #{report.source}: HTTP 429 (#{rate_limits}/" <>
              "#{ctx.max_rate_limits}), backing off #{wait} ms"
          )

          # Intentional Process.sleep: a dedicated Oban job process backing
          # off a throttling site; nothing else runs in this mailbox.
          Process.sleep(wait)
          loop(remaining, index, %{ctx | rate_limits: rate_limits}, report)
        end

      kind when kind in [:blocked, :layout_changed] ->
        halt(reason, index, report)

      _other ->
        errors = ctx.errors + 1
        report = record(report, wanted, {:error, reason})

        if errors >= @max_consecutive_errors,
          do: halt(reason, index + 1, report),
          else: continue(rest, index + 1, %{ctx | errors: errors, rate_limits: 0}, report)
    end
  end

  defp continue(rest, next_index, ctx, report) do
    report = %{report | next_index: next_index}

    case ctx.on_progress.(report) do
      :ok -> loop(rest, next_index, ctx, report)
      {:error, reason} -> {:error, {:checkpoint_failed, reason}, report}
      other -> {:error, {:checkpoint_failed, {:unexpected_result, other}}, report}
    end
  end

  defp halt(reason, index, report), do: {:error, reason, %{report | next_index: index}}

  defp search_one(ctx, wanted) do
    case ctx.source.search(wanted, []) do
      # A switched-off site answers every title with nothing; that is not
      # "not found", and walking the whole list would only hide it.
      {:ok, _items, %{disabled?: true}} -> {:error, :source_disabled}
      {:ok, items, meta} -> ingest_matches(ctx, wanted, items, meta)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest_matches(ctx, wanted, items, meta) do
    matches =
      for item <- items, {:match, via} <- [Matching.match(wanted, item)] do
        {stamp(item, wanted), via}
      end

    cond do
      Map.get(meta, :unsearchable?) == true ->
        {:ok, :unsearchable}

      matches == [] and items == [] ->
        {:ok, :not_found}

      matches == [] ->
        {:ok, {:no_match, length(items)}}

      true ->
        case Sync.ingest_items(ctx.provider, ctx.source, Enum.map(matches, &elem(&1, 0))) do
          {:ok, {movies, torrents}} ->
            {:ok, {:matched, movies, torrents, matches |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}}

          {:error, reason} ->
            {:error, {:persistence_failed, reason}}
        end
    end
  end

  # The wanted ids are authoritative once matched: the movie row is mapped
  # to the catalog's TMDB entry directly, never left to fuzzy matching.
  defp stamp(item, wanted) do
    title =
      case Map.get(item, :title) do
        title when is_binary(title) and title != "" -> title
        _ -> wanted.title
      end

    item
    |> Map.put(:tmdb_id, wanted.tmdb_id)
    |> Map.put(:imdb_id, Map.get(item, :imdb_id) || wanted.imdb_id)
    |> Map.put(:title, title)
  end

  defp record(report, wanted, outcome) do
    log_outcome(report.source, wanted, outcome)
    report = %{report | searched: report.searched + 1}

    case outcome do
      {:matched, movies, torrents, _via} ->
        %{
          report
          | matched: report.matched + 1,
            movies: report.movies + movies,
            torrents: report.torrents + torrents,
            matched_tmdb_ids: [wanted.tmdb_id | report.matched_tmdb_ids]
        }

      {:no_match, _candidates} ->
        %{report | no_match: report.no_match + 1}

      :not_found ->
        %{report | not_found: report.not_found + 1}

      :unsearchable ->
        %{report | unsearchable: report.unsearchable + 1}

      {:error, _reason} ->
        %{report | errors: report.errors + 1}
    end
  end

  defp log_outcome(source, wanted, outcome) do
    label = "tmdb=#{wanted.tmdb_id} #{inspect(wanted.title)} (#{wanted.year || "?"})"

    message =
      case outcome do
        {:matched, movies, torrents, via} ->
          "matched #{movies} post(s) via #{Enum.join(via, "+")} (#{torrents} torrents)"

        {:no_match, candidates} ->
          "no match among #{candidates} candidate post(s)"

        :not_found ->
          "no search result"

        :unsearchable ->
          "title has nothing searchable"

        {:error, reason} ->
          "error #{Sync.failure_state(reason)}: #{inspect(reason)}"
      end

    Logger.info("[Torrent TargetedSearch] #{source} #{label} -> #{message}")
  end

  defp log_finish({:ok, report} = result) do
    Logger.info("[Torrent TargetedSearch] #{report.source} done: #{summary(report)}")
    result
  end

  defp log_finish({:error, reason, report} = result) do
    Logger.error(
      "[Torrent TargetedSearch] #{report.source} halted state=#{Sync.failure_state(reason)} " <>
        "at index #{report.next_index}: #{inspect(reason)} (#{summary(report)})"
    )

    result
  end

  defp summary(report) do
    "searched=#{report.searched} matched=#{report.matched} no_match=#{report.no_match} " <>
      "not_found=#{report.not_found} unsearchable=#{report.unsearchable} " <>
      "errors=#{report.errors} movies=#{report.movies} torrents=#{report.torrents}"
  end

  defp backoff_ms({:rate_limited, %{retry_after_ms: ms}}, _default) when is_integer(ms), do: ms
  defp backoff_ms(_reason, default), do: default

  defp new_report(source_module, total, start_index) do
    %{
      source: source_slug(source_module),
      total: total,
      next_index: start_index,
      searched: 0,
      matched: 0,
      no_match: 0,
      not_found: 0,
      unsearchable: 0,
      errors: 0,
      movies: 0,
      torrents: 0,
      matched_tmdb_ids: []
    }
  end

  defp source_slug(source_module) do
    if Code.ensure_loaded?(source_module) and function_exported?(source_module, :slug, 0),
      do: source_module.slug(),
      else: inspect(source_module)
  end
end
