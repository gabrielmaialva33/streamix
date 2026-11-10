defmodule Streamix.Workers.ClassifyTitleTagsWorker do
  @moduledoc """
  Classifies titles that still need tags (`Streamix.Catalog.pending_tag_documents/2`)
  with `Streamix.AI.classify_titles/2`, `:batch_size` titles per request and
  `:concurrency` requests at a time, until `:limit` titles were handled or
  nothing is pending. A job's `"limit"` arg overrides the configured one.

  A spent daily quota, a rate limit, a missing or rejected key and transport
  or server failures end the run quietly: the next run continues where this
  one stopped. That is what lets the free tier work through the catalog a
  day's quota at a time.

  An answer that cannot be used (blocked, malformed, a title left out) is
  retried one title at a time; a title that still gets no answer is stored
  with empty facets so it is not asked about again until the vocabulary
  version changes.
  """

  use Oban.Worker,
    queue: :tags,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias Streamix.AI
  alias Streamix.Catalog

  require Logger

  @stop_reasons [:quota_exhausted, :rate_limited, :unauthorized, :not_configured]

  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(3)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    config = Application.get_env(:streamix, __MODULE__, [])

    run = %{
      limit: job_limit(args, Keyword.get(config, :limit, 2_000)),
      batch_size: Keyword.get(config, :batch_size, 20),
      concurrency: Keyword.get(config, :concurrency, 2),
      model: AI.tag_classifier_model()
    }

    {status, counts} =
      Enum.reduce_while([:movies, :series], {:ok, %{}}, fn kind, {:ok, counts} ->
        case classify_kind(kind, run, 0) do
          {:ok, done} -> {:cont, {:ok, Map.put(counts, kind, done)}}
          {:stopped, reason, done} -> {:halt, {{:stopped, reason}, Map.put(counts, kind, done)}}
        end
      end)

    Logger.info("[TagClassifier] run finished #{inspect(counts)} status=#{inspect(status)}")
    :ok
  end

  defp job_limit(%{"limit" => limit}, _default) when is_integer(limit) and limit > 0, do: limit
  defp job_limit(_args, default), do: default

  defp classify_kind(_kind, %{limit: limit}, done) when done >= limit, do: {:ok, done}

  defp classify_kind(kind, run, done) do
    wanted = min(run.batch_size * run.concurrency, run.limit - done)

    case Catalog.pending_tag_documents(kind, wanted) do
      [] ->
        {:ok, done}

      documents ->
        documents
        |> Enum.chunk_every(run.batch_size)
        |> Task.async_stream(&classify_batch(kind, &1, run.model),
          max_concurrency: run.concurrency,
          ordered: false,
          timeout: :timer.minutes(5),
          on_timeout: :kill_task
        )
        |> Enum.reduce({:ok, done}, &merge/2)
        |> continue(kind, run)
    end
  end

  defp merge({:ok, {:ok, n}}, {status, done}), do: {status, done + n}
  defp merge({:ok, {:stopped, reason}}, {_status, done}), do: {{:stopped, reason}, done}
  defp merge({:exit, reason}, {_status, done}), do: {{:stopped, {:exit, reason}}, done}

  defp continue({:ok, done}, kind, run), do: classify_kind(kind, run, done)
  defp continue({{:stopped, reason}, done}, _kind, _run), do: {:stopped, reason, done}

  # Classifies a batch and stores every title of it, or reports why the run
  # should stop. Returns how many titles were stored.
  defp classify_batch(kind, documents, model) do
    case AI.classify_titles(documents) do
      {:ok, results, _usage} ->
        answered = Map.new(results)
        {stored, missing} = Enum.split_with(documents, &Map.has_key?(answered, &1.variant_key))
        Enum.each(stored, &store(kind, &1, answered[&1.variant_key], model))
        retry_alone(kind, missing, model, length(stored))

      {:error, reason} ->
        if stop?(reason),
          do: {:stopped, reason},
          else: retry_alone(kind, documents, model, 0)
    end
  end

  # A lone title that still fails is stored empty; a stop reason still stops.
  defp retry_alone(_kind, [], _model, stored), do: {:ok, stored}

  defp retry_alone(kind, [document], model, stored) when stored == 0 do
    case AI.classify_titles([document]) do
      {:ok, [{_key, facets}], _usage} ->
        store(kind, document, facets, model)
        {:ok, 1}

      {:error, reason} ->
        if stop?(reason), do: {:stopped, reason}, else: store_empty(kind, document, model)

      {:ok, _other, _usage} ->
        store_empty(kind, document, model)
    end
  end

  defp retry_alone(kind, documents, model, stored) do
    Enum.reduce_while(documents, {:ok, stored}, fn document, {:ok, count} ->
      case retry_alone(kind, [document], model, 0) do
        {:ok, n} -> {:cont, {:ok, count + n}}
        stopped -> {:halt, stopped}
      end
    end)
  end

  defp store_empty(kind, document, model) do
    store(kind, document, %{}, model)
    {:ok, 1}
  end

  defp store(kind, document, facets, model) do
    {:ok, _tags} =
      Catalog.put_title_tags(stored_kind(kind), document.variant_key, facets, model,
        year: document[:year]
      )
  end

  defp stored_kind(:movies), do: "movies"
  defp stored_kind(:series), do: "series"

  defp stop?(reason) when reason in @stop_reasons, do: true
  defp stop?({:api_error, status}) when status >= 500, do: true
  defp stop?({:request_failed, _reason}), do: true
  defp stop?(_reason), do: false
end
