defmodule Streamix.Gindex.AnimeMatcher do
  @moduledoc """
  AniList-based best-match ranker for anime rows.

  Mirrors the scoring philosophy of `TmdbMatcher`: ask the provider for
  a short candidate list, re-rank locally on fuzzy title similarity so
  we don't just pick whatever AniList considers most popular. Anime has
  a stronger case for local ranking than TMDB because a single show can
  appear under 5+ titles (romaji, english, native, plus community
  synonyms including the Brazilian dub title). We compare the needle
  against all of them and keep the best score.
  """

  alias Streamix.Gindex.AnilistClient

  @min_score 450

  @type result :: %{
          anilist_id: integer(),
          title: String.t(),
          cover_url: String.t() | nil,
          season_year: integer() | nil,
          score: number()
        }

  @spec best_match(String.t(), integer() | nil) ::
          {:ok, result()} | {:miss, :no_results | :low_score | atom()}
  def best_match(title, year) when is_binary(title) and title != "" do
    with {:ok, candidates} <- search(title, year),
         [_ | _] = scored <- score_all(candidates, title, year) do
      best = Enum.max_by(scored, & &1.score)

      if best.score >= @min_score do
        {:ok,
         %{
           anilist_id: best.anilist_id,
           title: best.title_romaji || best.title_english || "",
           cover_url: best.cover_url,
           season_year: best.season_year,
           score: best.score
         }}
      else
        {:miss, :low_score}
      end
    else
      [] -> {:miss, :no_results}
      {:error, reason} -> {:miss, reason}
    end
  end

  def best_match(_, _), do: {:miss, :empty_title}

  # --- search ---

  defp search(title, year) do
    case AnilistClient.search_anime(title, year) do
      {:ok, [_ | _]} = ok ->
        ok

      {:ok, []} when not is_nil(year) ->
        AnilistClient.search_anime(title, nil)

      other ->
        other
    end
  end

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
    title_score(c, needle) + year_bonus(c.season_year, year) + popularity_bump(c.popularity)
  end

  # Try every available title variant + synonyms, take the best.
  defp title_score(c, needle) do
    candidates =
      [c.title_romaji, c.title_english, c.title_native | c.synonyms]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&normalize/1)

    Enum.reduce(candidates, 0, fn variant, acc ->
      max(acc, variant_score(variant, needle))
    end)
  end

  defp variant_score(variant, needle) when variant == needle, do: 1000

  defp variant_score(variant, needle) do
    fuzzy_from_sim(String.jaro_distance(variant, needle))
  end

  defp fuzzy_from_sim(sim) when sim >= 0.95, do: round(400 + (sim - 0.95) * 8000)
  defp fuzzy_from_sim(sim) when sim >= 0.80, do: round(400 + (sim - 0.80) * 2666)
  defp fuzzy_from_sim(_), do: 0

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
    round(:math.log2(pop + 1) * 5)
  end

  defp popularity_bump(_), do: 0

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
