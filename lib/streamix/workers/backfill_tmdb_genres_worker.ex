defmodule Streamix.Workers.BackfillTmdbGenresWorker do
  @moduledoc """
  Backfills canonical genres once per distinct TMDB id, across all providers.

  Each run reads at most 10,000 pending ids per kind, sequentially, through
  the token pool with a bare, uncached details request (a few KB, unlike the
  full cached detail fetch). Configure `:limit` and `:delay_ms` under
  `config :streamix, #{__MODULE__}` to tune the bounded nightly pass.

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

  require Logger

  # Failures of the whole TMDB path, not of one title: no point asking again.
  @stop_reasons [:rate_limited, :unauthorized, :tmdb_not_configured]

  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(2)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    config = Application.get_env(:streamix, __MODULE__, [])
    limit = Keyword.get(config, :limit, 10_000)
    delay = Keyword.get(config, :delay_ms, 100)

    Enum.reduce_while([{:movies, Movie}, {:series, Series}], :ok, fn {kind, schema}, :ok ->
      schema
      |> pending_ids(limit)
      |> fetch_kind(kind, delay)
      |> continue()
    end)
  end

  defp pending_ids(schema, limit) do
    Repo.all(
      from(row in schema,
        where: is_nil(row.tmdb_genre_ids),
        where: not is_nil(row.tmdb_id) and row.tmdb_id != "",
        distinct: true,
        order_by: row.tmdb_id,
        limit: ^limit,
        select: row.tmdb_id
      )
    )
  end

  defp fetch_kind(ids, kind, delay) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      kind |> fetch_and_apply(id, delay) |> continue()
    end)
  end

  defp fetch_and_apply(kind, id, delay) do
    result =
      with {:ok, genres} <- fetch_genres(kind, id),
           {:ok, _stats} <- Catalog.apply_tmdb_genres(kind, id, genres),
           do: :ok

    if delay > 0, do: Process.sleep(delay)

    case result do
      :ok -> :ok
      {:error, reason} when reason in @stop_reasons -> {:error, reason}
      {:error, {:transport_error, _}} = error -> error
      {:error, reason} -> skip(kind, id, reason)
    end
  end

  defp skip(kind, id, reason) do
    Logger.warning("[TMDB Genres] #{kind} #{id} skipped: #{inspect(reason)}")
    :ok
  end

  defp fetch_genres(kind, id) do
    case TmdbClient.get_genre_ids(tmdb_type(kind), id) do
      {:error, :not_found} -> {:ok, []}
      result -> result
    end
  end

  defp tmdb_type(:movies), do: :movie
  defp tmdb_type(:series), do: :tv

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _reason} = error), do: {:halt, error}
end
