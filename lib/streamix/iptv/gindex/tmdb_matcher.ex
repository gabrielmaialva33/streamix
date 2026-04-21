defmodule Streamix.Iptv.Gindex.TmdbMatcher do
  @moduledoc """
  Multi-stage TMDB matcher for gindex catalog rows.

  The caller passes a `{title, year, kind}` triple — we ask TMDB for
  candidates, score each locally, and return the best one (or `:miss`).
  TMDB's own ranking boosts popularity, which is wrong for our use case:
  a popular "The Matrix Reloaded" might outrank the plain "The Matrix"
  for someone who typed just "Matrix". A local re-rank fixes that.

  Scoring:

    * `original_title` exact match           → 1000
    * translated `title` exact match (pt-BR) →  900
    * Jaro-Winkler ≥ 0.80                    →  400..800 (scaled)
    * Year match within ±1                   → +150
    * Year match within ±2                   →  +75
    * `log2(popularity + 1) * 8`             → tie-breaker only

  Results below `@min_score` are treated as a miss so we don't persist
  wildly unrelated posters.
  """

  alias Streamix.Iptv.TmdbClient

  require Logger

  @min_score 500

  @type kind :: :movie | :series
  @type candidate :: %{
          tmdb_id: String.t(),
          title: String.t(),
          original_title: String.t(),
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          year: integer() | nil,
          popularity: float(),
          score: number(),
          original_language: String.t() | nil
        }

  @spec best_match(String.t(), integer() | nil, kind()) ::
          {:ok, candidate()} | {:miss, :no_results | :low_score | atom()}
  def best_match(title, year, kind) when is_binary(title) and title != "" do
    with {:ok, candidates} <- search(title, year, kind),
         [_ | _] = scored <- score_all(candidates, title, year) do
      best = Enum.max_by(scored, & &1.score)

      if best.score >= @min_score do
        {:ok, best}
      else
        {:miss, :low_score}
      end
    else
      {:ok, []} -> {:miss, :no_results}
      [] -> {:miss, :no_results}
      {:error, reason} -> {:miss, reason}
    end
  end

  def best_match(_title, _year, _kind), do: {:miss, :empty_title}

  # --- search pipeline ---

  # Try with year first; if TMDB returns nothing, retry without it —
  # filenames lie about years more often than TMDB lies about titles.
  defp search(title, year, kind) do
    opts = [profile: :gindex, year: year]

    case do_search(kind, title, opts) do
      {:ok, %{"results" => [_ | _] = rs}} ->
        {:ok, Enum.map(rs, &normalize(&1, kind))}

      {:ok, %{"results" => []}} when not is_nil(year) ->
        case do_search(kind, title, Keyword.delete(opts, :year)) do
          {:ok, %{"results" => rs}} -> {:ok, Enum.map(rs, &normalize(&1, kind))}
          err -> err
        end

      {:ok, %{"results" => []}} ->
        {:ok, []}

      other ->
        other
    end
  end

  defp do_search(:movie, query, opts), do: TmdbClient.search_movie(query, opts)
  defp do_search(:series, query, opts), do: TmdbClient.search_series(query, opts)

  # Normalize the two TMDB endpoints into a common candidate shape.
  # `movie` uses title/release_date, `tv` uses name/first_air_date.
  defp normalize(result, :movie) do
    %{
      tmdb_id: to_string(result["id"]),
      title: result["title"] || "",
      original_title: result["original_title"] || result["title"] || "",
      poster_path: result["poster_path"],
      backdrop_path: result["backdrop_path"],
      year: extract_year(result["release_date"]),
      popularity: result["popularity"] || 0.0,
      original_language: result["original_language"]
    }
  end

  defp normalize(result, :series) do
    %{
      tmdb_id: to_string(result["id"]),
      title: result["name"] || "",
      original_title: result["original_name"] || result["name"] || "",
      poster_path: result["poster_path"],
      backdrop_path: result["backdrop_path"],
      year: extract_year(result["first_air_date"]),
      popularity: result["popularity"] || 0.0,
      original_language: result["original_language"]
    }
  end

  defp extract_year(nil), do: nil
  defp extract_year(""), do: nil

  defp extract_year(str) when is_binary(str) do
    case Regex.run(~r/^(\d{4})/, str, capture: :all_but_first) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  # --- scoring ---

  defp score_all(candidates, title, year) do
    needle = normalize_for_compare(title)

    candidates
    |> Enum.map(fn c ->
      base = base_title_score(c, needle)
      year_bonus = year_bonus(c.year, year)
      pop = popularity_bump(c.popularity)
      Map.put(c, :score, base + year_bonus + pop)
    end)
    |> Enum.filter(fn c -> c.score > 0 end)
  end

  defp base_title_score(c, needle) do
    orig = normalize_for_compare(c.original_title)
    tr = normalize_for_compare(c.title)

    cond do
      orig == needle -> 1000
      tr == needle -> 900
      true -> fuzzy_score(needle, orig, tr)
    end
  end

  defp fuzzy_score(needle, orig, tr) do
    # Take the better of the two field comparisons. Jaro-Winkler is
    # friendlier than Levenshtein for short queries with transpositions.
    sim = max(String.jaro_distance(needle, orig), String.jaro_distance(needle, tr))

    cond do
      sim >= 0.95 -> round(400 + (sim - 0.95) * 8000)
      sim >= 0.80 -> round(400 + (sim - 0.80) * 2666)
      true -> 0
    end
  end

  defp year_bonus(nil, _), do: 0
  defp year_bonus(_, nil), do: 0

  defp year_bonus(a, b) do
    case abs(a - b) do
      0 -> 150
      1 -> 100
      2 -> 50
      _ -> 0
    end
  end

  defp popularity_bump(pop) when is_number(pop) and pop > 0 do
    round(:math.log2(pop + 1) * 8)
  end

  defp popularity_bump(_), do: 0

  # Fold case, strip accents and non-alphanum so "13 Reasons Why" matches
  # "13 reasons why" matches "13 reasons why". `unaccent` would be nicer
  # but we'd pay a DB round-trip; this string-level fold is good enough
  # for the similarity pass.
  defp normalize_for_compare(str) when is_binary(str) do
    str
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\p{Mn}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_for_compare(_), do: ""
end
