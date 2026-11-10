defmodule Streamix.Workers.BackfillTmdbMetadataWorker do
  @moduledoc """
  Backfills TMDB genres, keywords and credits once per distinct TMDB id,
  across all providers.

  A title is pending while either `tmdb_genre_ids` or `tmdb_keyword_ids` is
  NULL. Each run reads at most `:limit` pending ids per kind through the token
  pool, `:concurrency` at a time, with an uncached details request carrying
  only keywords and credits (no videos or images). Configure `:limit`,
  `:concurrency` and `:delay_ms` under `config :streamix, #{__MODULE__}`; a
  job's `"limit"` arg overrides the configured one, for a one-off catch-up.

  A 404 is a completed empty answer. Rate limiting, a missing or rejected
  token and transport failures stop the run; any other error skips that id,
  which stays pending for a later run. The client's own 429 retries happen
  before it returns `:rate_limited` here.
  """

  use Oban.Worker,
    queue: :tmdb_details,
    max_attempts: 3,
    priority: 3,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias Streamix.Catalog
  alias Streamix.Iptv.{Movie, Series, TmdbClient}
  alias Streamix.Repo
  alias Streamix.SafeLog

  require Logger

  # Failures of the whole TMDB path, not of one title: no point asking again.
  @stop_reasons [:rate_limited, :unauthorized, :tmdb_not_configured]
  @empty_answer %{genre_ids: [], keywords: [], credits: []}

  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(6)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    config = Application.get_env(:streamix, __MODULE__, [])
    limit = job_limit(args, Keyword.get(config, :limit, 10_000))
    opts = %{delay: Keyword.get(config, :delay_ms, 100), concurrency: concurrency(config)}

    Enum.reduce_while([{:movies, Movie}, {:series, Series}], :ok, fn {kind, schema}, :ok ->
      schema
      |> pending_ids(limit)
      |> fetch_kind(kind, opts)
      |> continue()
    end)
  end

  defp job_limit(%{"limit" => limit}, _default) when is_integer(limit) and limit > 0, do: limit
  defp job_limit(_args, default), do: default

  defp concurrency(config) do
    case Keyword.get(config, :concurrency, 1) do
      n when is_integer(n) and n > 0 -> n
      _other -> 1
    end
  end

  defp pending_ids(schema, limit) do
    Repo.all(
      from(row in schema,
        where: is_nil(row.tmdb_genre_ids) or is_nil(row.tmdb_keyword_ids),
        where: not is_nil(row.tmdb_id) and row.tmdb_id != "",
        distinct: true,
        order_by: row.tmdb_id,
        limit: ^limit,
        select: row.tmdb_id
      )
    )
  end

  defp fetch_kind(ids, kind, %{concurrency: concurrency, delay: delay}) do
    ids
    |> Task.async_stream(&fetch_and_apply(kind, &1, delay),
      max_concurrency: concurrency,
      ordered: false,
      timeout: :timer.minutes(2),
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, result}, :ok -> continue(result)
      {:exit, reason}, :ok -> continue(skip(kind, :timeout, reason))
    end)
  end

  defp fetch_and_apply(kind, id, delay) do
    result =
      with {:ok, metadata} <- fetch_metadata(kind, id),
           {:ok, genre_ids} <- genre_ids(metadata),
           {:ok, _stats} <- Catalog.apply_tmdb_genres(kind, id, genre_ids),
           {:ok, _stats} <- Catalog.apply_tmdb_metadata(kind, id, metadata),
           do: :ok

    if delay > 0, do: Process.sleep(delay)

    case result do
      :ok -> :ok
      {:error, reason} when reason in @stop_reasons -> {:error, reason}
      {:error, {:transport_error, _}} = error -> error
      {:error, reason} -> skip(kind, id, reason)
    end
  end

  # An answer without a genre list is not an answer: the title stays pending.
  defp genre_ids(%{genre_ids: ids}) when is_list(ids), do: {:ok, ids}
  defp genre_ids(_metadata), do: {:error, :missing_genres}

  defp skip(kind, id, reason) do
    Logger.warning("[TMDB Metadata] title skipped",
      content_type: kind,
      content_ref: "tmdb:#{id}",
      reason: SafeLog.redact_inspect(reason)
    )

    :ok
  end

  defp fetch_metadata(kind, id) do
    case TmdbClient.get_metadata(tmdb_type(kind), id) do
      {:error, :not_found} -> {:ok, @empty_answer}
      result -> result
    end
  end

  defp tmdb_type(:movies), do: :movie
  defp tmdb_type(:series), do: :tv

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _reason} = error), do: {:halt, error}
end
