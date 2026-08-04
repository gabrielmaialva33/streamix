defmodule Streamix.AI.SemanticSearch do
  @moduledoc """
  Semantic search and recommendations using vector embeddings.

  Provides high-level functions for:
  - Searching content by natural language queries
  - Finding similar content (recommendations)
  - Indexing content for search

  ## Usage

      # Search movies by description
      SemanticSearch.search("action movie with car chases", :movies, limit: 10)

      # Find similar content
      SemanticSearch.similar(movie_id, :movies, limit: 5)

      # Index content
      SemanticSearch.index_content(movie, :movies)
  """

  require Logger

  alias Streamix.AI.{Embeddings, Qdrant}
  alias Streamix.Repo

  import Ecto.Query

  # The NVIDIA endpoint accepts 64 E5 inputs in one request (also within
  # Gemini's batch API envelope). Sending 10 made a full production backfill
  # take most of a day without reducing the number of billable inputs.
  @batch_size 64
  # Keep the hosted endpoint allocation conservative at 40 requests/minute.
  # Express the delay as derivation-from-rate so the relationship survives
  # someone bumping the cap without bumping the other constant.
  @requests_per_minute 40
  @rate_limit_delay div(60_000, @requests_per_minute)

  # Public API

  @doc """
  Checks if semantic search is available.
  """
  def available? do
    Embeddings.enabled?() and Qdrant.enabled?()
  end

  @doc """
  Initializes the search system (creates collections).
  """
  def setup do
    if available?() do
      Qdrant.setup_collections()
    else
      Logger.warning("[SemanticSearch] Not available - check embeddings and Qdrant config")
      {:error, :not_available}
    end
  end

  @doc """
  Ensures vector collections exist without requiring Qdrant to be healthy first.

  This is intended for retryable startup work. An intentionally disabled AI
  subsystem is a successful no-op, while a configured but unavailable Qdrant
  returns its connection error so the caller can retry.
  """
  def bootstrap_collections do
    if Embeddings.enabled?() and Qdrant.configured?() do
      Qdrant.setup_collections()
    else
      {:ok, :disabled}
    end
  end

  @doc """
  Searches for content using natural language query.

  ## Parameters
  - `query` - Natural language search query
  - `collection` - Collection to search (:movies, :series, :animes)
  - `opts` - Options:
    - `:limit` - Max results (default: 10)
    - `:provider_id` - Filter by provider
    - `:min_score` - Minimum similarity score (default: 0.7)

  ## Returns
  `{:ok, [%{id, score, title, year, ...}]}` or `{:error, reason}`
  """
  def search(query, collection, opts \\ []) when is_atom(collection) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.7)
    provider_id = Keyword.get(opts, :provider_id)

    filter = build_filter(provider_id: provider_id)

    search_opts = [
      limit: limit,
      score_threshold: min_score,
      filter: filter
    ]

    case Qdrant.search_by_text(to_string(collection), query, search_opts) do
      {:ok, results} ->
        formatted = format_results(results)
        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Finds content similar to a given content ID.

  ## Parameters
  - `content_id` - ID of the source content
  - `collection` - Collection (:movies, :series, :animes)
  - `opts` - Options:
    - `:limit` - Max results (default: 5)
    - `:cross_provider` - Include results from other providers (default: true)
  """
  def similar(content_id, collection, opts \\ []) when is_atom(collection) do
    limit = Keyword.get(opts, :limit, 5)

    search_opts = [limit: limit]

    case Qdrant.find_similar(to_string(collection), content_id, search_opts) do
      {:ok, results} ->
        formatted = format_results(results)
        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Indexes a single content item for search.

  ## Parameters
  - `content` - Content struct (Movie, Series, Anime) with title, description, etc.
  - `collection` - Target collection (:movies, :series, :animes)
  """
  def index_content(content, collection) when is_atom(collection) do
    content_map = content_to_map(content)

    case Embeddings.embed_content(content_map) do
      {:ok, vector} ->
        payload = build_payload(content_map)
        Qdrant.upsert_point(to_string(collection), content.id, vector, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Indexes multiple content items in batch.

  Respects NVIDIA rate limits by processing in batches with delays.
  Returns the count of successfully indexed items.
  """
  def index_contents(contents, collection, opts \\ [])
      when is_list(contents) and is_atom(collection) do
    batch_indexer = Keyword.get(opts, :batch_indexer, &index_batch/2)
    rate_limit_delay = Keyword.get(opts, :rate_limit_delay, @rate_limit_delay)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    on_batch = Keyword.get(opts, :on_batch, fn _last_id, _indexed_total -> :ok end)
    total_contents = length(contents)

    batches =
      contents
      |> Enum.map(&content_to_map/1)
      |> Enum.chunk_every(batch_size)

    total_batches = length(batches)

    context = %{
      batch_indexer: batch_indexer,
      collection: collection,
      on_batch: on_batch,
      rate_limit_delay: rate_limit_delay,
      total_batches: total_batches,
      total_contents: total_contents
    }

    batches
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, &index_content_batch(&1, &2, context))
  end

  defp index_content_batch({batch, batch_number}, {:ok, count}, context) do
    batch
    |> context.batch_indexer.(context.collection)
    |> handle_index_batch(batch, batch_number, count, context)
  end

  defp handle_index_batch({:ok, indexed}, batch, batch_number, count, context) do
    indexed_total = count + indexed
    last_id = batch |> List.last() |> Map.fetch!(:id)

    case report_index_checkpoint(context.on_batch, last_id, indexed_total) do
      :ok ->
        maybe_log_index_progress(batch_number, indexed_total, context)
        maybe_wait_for_next_batch(batch_number, context)

        {:cont, {:ok, indexed_total}}

      {:error, reason} ->
        Logger.error("[SemanticSearch] Checkpoint persistence failed: #{inspect(reason)}")
        {:halt, {:error, {:checkpoint_failed, context.collection, count, reason}}}
    end
  end

  defp handle_index_batch({:error, reason}, _batch, _batch_number, count, context) do
    Logger.error("[SemanticSearch] Batch indexing failed: #{inspect(reason)}")
    {:halt, {:error, {:batch_failed, context.collection, count, reason}}}
  end

  defp report_index_checkpoint(callback, last_id, indexed_total)
       when is_function(callback, 2) do
    case callback.(last_id, indexed_total) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp maybe_log_index_progress(batch_number, indexed_total, context) do
    if rem(batch_number, 10) == 0 or batch_number == context.total_batches do
      Logger.info(
        "[SemanticSearch] #{context.collection} batch #{batch_number}/#{context.total_batches}, " <>
          "#{indexed_total}/#{context.total_contents} indexed"
      )
    end
  end

  defp maybe_wait_for_next_batch(batch_number, context) do
    if batch_number < context.total_batches, do: Process.sleep(context.rate_limit_delay)
  end

  @doc """
  Indexes all movies from database.

  Use with caution - this can take a long time for large datasets.
  Consider using the background worker instead.
  """
  def index_all_movies(provider_id \\ nil, opts \\ []) do
    after_id = Keyword.get(opts, :after_id, 0)

    query =
      from(m in Streamix.Iptv.Movie,
        join: provider in Streamix.Iptv.Provider,
        on: provider.id == m.provider_id,
        where: not is_nil(m.title) and m.id > ^after_id,
        where: provider.is_active == true,
        order_by: [asc: m.id],
        preload: [:genres]
      )

    query =
      if provider_id,
        do: where(query, [m, _provider], m.provider_id == ^provider_id),
        else: query

    movies =
      query
      |> Repo.all()
      |> Enum.map(fn m ->
        %{
          id: m.id,
          title: m.title,
          plot: m.plot,
          year: m.year,
          genres: Streamix.Helpers.genre_names(m.genres),
          rating: m.rating,
          provider_id: m.provider_id
        }
      end)

    Logger.info("[SemanticSearch] Indexing #{length(movies)} movies after id #{after_id}")

    index_contents(movies, :movies, opts)
  end

  @doc """
  Indexes all series from database.
  """
  def index_all_series(provider_id \\ nil, opts \\ []) do
    after_id = Keyword.get(opts, :after_id, 0)

    query =
      from(s in Streamix.Iptv.Series,
        join: provider in Streamix.Iptv.Provider,
        on: provider.id == s.provider_id,
        where: not is_nil(s.title) and s.id > ^after_id,
        where: provider.is_active == true,
        order_by: [asc: s.id],
        preload: [:genres]
      )

    query =
      if provider_id,
        do: where(query, [s, _provider], s.provider_id == ^provider_id),
        else: query

    series =
      query
      |> Repo.all()
      |> Enum.map(fn s ->
        %{
          id: s.id,
          title: s.title,
          plot: s.plot,
          year: s.year,
          genres: Streamix.Helpers.genre_names(s.genres),
          rating: s.rating,
          provider_id: s.provider_id
        }
      end)

    Logger.info("[SemanticSearch] Indexing #{length(series)} series after id #{after_id}")

    index_contents(series, :series, opts)
  end

  @doc """
  Returns stats about indexed content.
  """
  def stats do
    collections = [:movies, :series, :animes, :user_profiles]

    collection_stats =
      Enum.map(collections, fn col ->
        case Qdrant.collection_info(to_string(col)) do
          {:ok, info} -> {col, info}
          {:error, _} -> {col, %{vectors_count: 0, status: "not_found"}}
        end
      end)
      |> Map.new()

    {:ok, collection_stats}
  end

  @doc """
  Returns detailed info about the semantic search system.
  """
  def info do
    %{
      available: available?(),
      embeddings: Embeddings.info(),
      qdrant_enabled: Qdrant.enabled?()
    }
  end

  # Private functions

  defp index_batch(contents, collection) do
    case Embeddings.embed_contents(contents) do
      {:ok, embeddings} ->
        points =
          Enum.map(embeddings, fn {id, vector} ->
            content = Enum.find(contents, &(&1.id == id))
            payload = build_payload(content)
            {id, vector, payload}
          end)

        Qdrant.upsert_points(to_string(collection), points)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_to_map(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.take([:id, :title, :description, :plot, :year, :genre, :genres, :rating, :provider_id])
    |> normalize_genres()
  end

  defp content_to_map(map) when is_map(map), do: normalize_genres(map)

  defp normalize_genres(%{genre: genre} = map) when is_binary(genre) do
    genres = String.split(genre, ",") |> Enum.map(&String.trim/1)
    map |> Map.delete(:genre) |> Map.put(:genres, genres)
  end

  defp normalize_genres(%{genres: genres} = map) when is_binary(genres) do
    Map.put(map, :genres, String.split(genres, ",") |> Enum.map(&String.trim/1))
  end

  defp normalize_genres(map), do: map

  defp build_payload(content) do
    %{
      title: content[:title],
      year: content[:year],
      genres: content[:genres] || [],
      rating: normalize_rating(content[:rating]),
      provider_id: content[:provider_id]
    }
  end

  defp build_filter(opts) do
    must = []

    must =
      if provider_id = opts[:provider_id] do
        [%{key: "provider_id", match: %{value: provider_id}} | must]
      else
        must
      end

    if must == [] do
      nil
    else
      %{must: must}
    end
  end

  defp format_results(results) do
    Enum.map(results, fn %{id: id, score: score, payload: payload} ->
      %{
        id: id,
        score: Float.round(score, 3),
        title: payload["title"],
        year: payload["year"],
        genres: payload["genres"] || [],
        rating: payload["rating"],
        provider_id: payload["provider_id"]
      }
    end)
  end

  defp normalize_rating(%Decimal{} = rating), do: Decimal.to_float(rating)
  defp normalize_rating(rating) when is_number(rating), do: rating
  defp normalize_rating(_rating), do: nil
end
