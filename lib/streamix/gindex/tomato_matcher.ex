defmodule Streamix.Gindex.TomatoMatcher do
  @moduledoc """
  Best-match ranker for TomatoAnimes search results.

  The Tomato catalog is small and anime-only (~2k entries), so even a
  loose Jaro-Winkler match against the single `name` field is high
  precision — there's no chance of colliding with a live-action title
  the way TMDB would. We keep the scoring shape consistent with
  `TmdbMatcher` / `AnimeMatcher` so the worker can treat all three as
  interchangeable best-match sources.
  """

  alias Streamix.Gindex.TomatoClient

  # Raised from 450 after the first production pass produced pairings
  # like "07-Ghost" → "MF GHOST" (priority=0 floor + single word overlap
  # on "ghost" was enough to win). 700 now requires the result to come
  # back in Tomato's top-2 slots AND pass both sanity checks below.
  @min_score 700
  # Absolute minimum Jaro-Winkler between needle and candidate name.
  # Translation-aware matches ("Ao no Exorcist" → "Blue Exorcist") land
  # around 0.55; unrelated shares-one-word pairings ("07-Ghost" → "MF
  # Ghost") land ~0.4 — 0.5 is the clean cut.
  @min_jaro 0.5
  # When both sides carry a year, anything past this gap almost always
  # means we matched on a similarly-named spin-off/movie instead of the
  # actual title.
  @max_year_drift 3

  @type result :: %{
          tomato_id: integer(),
          name: String.t(),
          cover_url: String.t() | nil,
          year: integer() | nil,
          dubbed: boolean(),
          score: number()
        }

  @spec best_match(String.t(), integer() | nil) ::
          {:ok, result()} | {:miss, :no_results | :low_score | atom()}
  def best_match(title, year) when is_binary(title) and title != "" do
    with {:ok, [_ | _] = candidates} <- TomatoClient.search_anime(title),
         [_ | _] = scored <- score_all(candidates, title, year) do
      best = Enum.max_by(scored, & &1.score)

      if best.score >= @min_score do
        {:ok,
         %{
           tomato_id: best.tomato_id,
           name: best.name,
           cover_url: best.image,
           year: best.year,
           dubbed: best.dubbed,
           score: best.score
         }}
      else
        {:miss, :low_score}
      end
    else
      {:ok, []} -> {:miss, :no_results}
      [] -> {:miss, :no_results}
      {:error, reason} -> {:miss, reason}
    end
  end

  def best_match(_, _), do: {:miss, :empty_title}

  # --- scoring ---

  defp score_all(candidates, title, year) do
    needle = normalize(title)

    candidates
    |> Enum.map(fn c ->
      Map.put(c, :score, score(c, needle, year))
    end)
    |> Enum.filter(&(&1.score > 0))
  end

  defp score(c, needle, year) do
    fuzzy = name_score(c.name, needle)

    # Tomato does its own synonym mapping server-side (e.g. "Ao no
    # Exorcist" → "Blue Exorcist"), which our local fuzzy can't see. If
    # Tomato places the result in the top 3 we apply a confidence floor,
    # but only after passing three guards that keep us from accepting
    # wildly unrelated covers for queries Tomato doesn't actually have:
    #
    #   1. word overlap — at least one 4+ char word in common,
    #   2. Jaro minimum — 0.5 rules out "07-Ghost" → "MF Ghost",
    #   3. year drift  — when both sides know a year, keep them close.
    confidence_floor =
      cond do
        not has_significant_overlap?(c.name, needle) -> 0
        below_min_jaro?(c.name, needle) -> 0
        year_too_far?(c.year, year) -> 0
        true -> priority_floor(c.priority)
      end

    max(fuzzy, confidence_floor) + year_bonus(c.year, year)
  end

  defp priority_floor(0), do: 850
  defp priority_floor(1), do: 700
  defp priority_floor(2), do: 550
  defp priority_floor(_), do: 0

  defp below_min_jaro?(name, needle) do
    String.jaro_distance(normalize(name), needle) < @min_jaro
  end

  defp year_too_far?(cand_year, query_year)
       when is_integer(cand_year) and is_integer(query_year) do
    abs(cand_year - query_year) > @max_year_drift
  end

  defp year_too_far?(_, _), do: false

  # Any word of 4+ characters common to both strings (after accent +
  # punctuation normalization) counts as "shared semantics". Guards the
  # top-3 floor without needing full translation coverage.
  defp has_significant_overlap?(name, needle) do
    name_words = name |> normalize() |> String.split() |> Enum.filter(&(String.length(&1) >= 4))
    needle_words = String.split(needle)

    name_set = MapSet.new(name_words)
    needle_set = MapSet.new(needle_words)

    not MapSet.disjoint?(name_set, needle_set)
  end

  defp name_score(name, needle) do
    normalized = normalize(name)

    if normalized == needle, do: 1000, else: fuzzy_score(needle, normalized)
  end

  defp fuzzy_score(needle, other) do
    sim = String.jaro_distance(needle, other)

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

  defp normalize(str) when is_binary(str) do
    str
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\p{Mn}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize(_), do: ""
end
