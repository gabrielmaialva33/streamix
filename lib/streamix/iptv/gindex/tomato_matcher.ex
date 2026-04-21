defmodule Streamix.Iptv.Gindex.TomatoMatcher do
  @moduledoc """
  Best-match ranker for TomatoAnimes search results.

  The Tomato catalog is small and anime-only (~2k entries), so even a
  loose Jaro-Winkler match against the single `name` field is high
  precision — there's no chance of colliding with a live-action title
  the way TMDB would. We keep the scoring shape consistent with
  `TmdbMatcher` / `AnimeMatcher` so the worker can treat all three as
  interchangeable best-match sources.
  """

  alias Streamix.Iptv.Gindex.TomatoClient

  @min_score 450

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
    # Tomato places the result in the top 3 *and* the returned name
    # shares a significant word with the query, we take that as a real
    # translation match and apply a confidence floor. Without the word
    # guard we'd paste wildly unrelated covers for queries Tomato
    # doesn't have (e.g. "Aa! Megami-sama!" → "The Café Terrace and Its
    # Goddesses", because their DB relates the word "goddess").
    confidence_floor =
      if has_significant_overlap?(c.name, needle) do
        case c.priority do
          0 -> 850
          1 -> 700
          2 -> 550
          _ -> 0
        end
      else
        0
      end

    max(fuzzy, confidence_floor) + year_bonus(c.year, year)
  end

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

    cond do
      normalized == needle -> 1000
      true -> fuzzy_score(needle, normalized)
    end
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
