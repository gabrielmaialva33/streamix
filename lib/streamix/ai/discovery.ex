defmodule Streamix.AI.Discovery do
  @moduledoc """
  Hybrid discovery search: "terror dos anos 80 leve" as filters plus meaning.

  The query is parsed by the catalog (`Streamix.Catalog.parse_discovery_query/1`)
  into genres, decades and tags. What every indexed title carries becomes a
  hard Qdrant filter:

    * the genres the query names (any of them);
    * a decade: released in it, or classified as set in it;
    * the providers the viewer may see, when given.

  Tags only some titles have yet (subgenres, mood, setting...) and genres a
  subgenre implies only add to the score, so a title still waiting for
  classification is ranked lower, never hidden. Similarity comes from the
  embedding of the whole query, which also carries what the parser left
  over. When that leftover names a credited person ("filmes do christopher
  nolan", `Streamix.Catalog.titles_by_people/1`), each collection is narrowed
  to that person's titles.

  Results are one per title (`variant_key`), best first.
  """

  alias Streamix.AI.{Embeddings, Qdrant, ScoreThresholds}
  alias Streamix.{Cache, Catalog}

  @tag_facets ~w(subgenres moods pace eras settings audience themes origins)a
  @tag_boost 0.04
  @genre_boost 0.03
  @rating_boost 0.002

  @type result :: %{
          id: integer(),
          score: float(),
          variant_key: String.t() | nil,
          title: String.t() | nil,
          year: integer() | nil,
          matched: [atom()]
        }

  @doc """
  Searches one collection (`:movies`, `:series`, `:animes`), or several
  with a list, embedding the query once; with a list, `:results` maps each
  collection to its results.

  Options: `:limit` per collection (default 24), `:provider_ids` (restrict
  to these providers; nil searches every provider).
  """
  @spec discover(String.t(), atom() | [atom()], keyword()) ::
          {:ok,
           %{results: [result()] | %{atom() => [result()]}, parsed: map(), people: [String.t()]}}
          | {:error, term()}
  def discover(query, collections, opts \\ [])

  def discover(query, collection, opts) when is_atom(collection) do
    with {:ok, %{results: results} = found} <- discover(query, [collection], opts) do
      {:ok, %{found | results: Map.fetch!(results, collection)}}
    end
  end

  def discover(query, collections, opts) when is_binary(query) and is_list(collections) do
    parsed = Catalog.parse_discovery_query(query)
    people = Catalog.titles_by_people(parsed.terms)
    limit = Keyword.get(opts, :limit, 24)

    structured? = Catalog.discovery_query_structured?(parsed) or people.people != []

    base = %{
      limit: max(limit * 6, 120),
      filter: filter(parsed, Keyword.get(opts, :provider_ids)),
      # A structured query already narrowed the field; keep its whole tail.
      score_threshold: if(structured?, do: 0.0, else: ScoreThresholds.query())
    }

    with {:ok, vector} <- query_vector(query),
         {:ok, results} <- search_all(collections, vector, base, {parsed, people}, limit) do
      {:ok, %{results: results, parsed: parsed, people: people.people}}
    end
  end

  defp search_all(collections, vector, base, {parsed, people}, limit) do
    Enum.reduce_while(collections, {:ok, %{}}, fn collection, {:ok, acc} ->
      case search_collection(collection, vector, base, people) do
        {:ok, hits} -> {:cont, {:ok, Map.put(acc, collection, ranked(hits, parsed, limit))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A named person narrows each collection to that person's titles; one
  # with none of them in this collection has nothing to search.
  defp search_collection(collection, vector, base, %{people: []}) do
    Qdrant.search(to_string(collection), vector, Map.to_list(base))
  end

  defp search_collection(collection, vector, base, people) do
    case person_keys(people, collection) do
      [] ->
        {:ok, []}

      keys ->
        filter = with_condition(base.filter, %{key: "variant_key", match: %{any: keys}})
        Qdrant.search(to_string(collection), vector, Map.to_list(%{base | filter: filter}))
    end
  end

  defp person_keys(people, :movies), do: people.movies
  defp person_keys(people, collection) when collection in [:series, :animes], do: people.series

  defp with_condition(nil, condition), do: %{must: [condition]}
  defp with_condition(%{must: must}, condition), do: %{must: must ++ [condition]}

  defp ranked(hits, parsed, limit) do
    hits
    |> Enum.uniq_by(fn %{id: id, payload: payload} -> payload["variant_key"] || {:id, id} end)
    |> Enum.map(&rank(&1, parsed))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  # Typing "terror anos 80" patches the search a few times on the way, and
  # the embedding API allows 40 requests a minute for everyone: a query's
  # vector is kept in this node's memory for a while. Failures are not.
  @vector_ttl :timer.minutes(30)

  defp query_vector(query) do
    key = {__MODULE__, :vector, query |> String.trim() |> String.downcase()}

    fetched =
      Cache.fetch_local(key, @vector_ttl, fn ->
        case Embeddings.embed(query, input_type: :query) do
          {:ok, vector} -> vector
          {:error, _reason} -> nil
        end
      end)

    if fetched, do: {:ok, fetched}, else: {:error, :embedding_failed}
  end

  # --- Filter ---

  @doc false
  def filter(parsed, provider_ids) do
    must =
      [
        provider_condition(provider_ids),
        genre_condition(parsed.genres),
        decade_condition(parsed.decades, Map.get(parsed.tags, :eras, []))
      ]
      |> Enum.reject(&is_nil/1)

    if must == [], do: nil, else: %{must: must}
  end

  defp provider_condition(nil), do: nil
  defp provider_condition(ids) when is_list(ids), do: %{key: "provider_id", match: %{any: ids}}

  defp genre_condition([]), do: nil

  defp genre_condition(slugs),
    do: %{key: "genres", match: %{any: Enum.map(slugs, &Catalog.genre_name/1)}}

  defp decade_condition([], _eras), do: nil

  defp decade_condition(decades, eras) do
    released =
      Enum.map(decades, &%{key: "year", range: %{gte: &1, lte: &1 + 9}})

    set_in = if eras == [], do: [], else: [%{key: "eras", match: %{any: eras}}]
    %{should: released ++ set_in}
  end

  # --- Ranking ---

  defp rank(%{id: id, score: score, payload: payload}, parsed) do
    matched =
      Enum.filter(@tag_facets, fn facet ->
        wanted = Map.get(parsed.tags, facet, [])
        wanted != [] and overlap?(payload[Atom.to_string(facet)], wanted)
      end)

    implied? =
      parsed.implied_genres != [] and
        overlap?(payload["genres"], Enum.map(parsed.implied_genres, &Catalog.genre_name/1))

    boost =
      length(matched) * @tag_boost +
        if(implied?, do: @genre_boost, else: 0.0) +
        rating(payload["rating"]) * @rating_boost

    %{
      id: id,
      score: Float.round(score + boost, 4),
      variant_key: payload["variant_key"],
      title: payload["title"],
      year: payload["year"],
      matched: matched
    }
  end

  defp overlap?(values, wanted), do: values |> List.wrap() |> Enum.any?(&(&1 in wanted))

  defp rating(rating) when is_number(rating) and rating > 0, do: min(rating, 10)
  defp rating(_rating), do: 0
end
