defmodule Streamix.Iptv.Content.VariantCards do
  @moduledoc """
  Collapses provider variants of the same title into one canonical card.

  Providers list the same movie/series several times — per quality (4K,
  HDR), per language (dubbed/subbed), or with the release year embedded
  in the name — and often disagree on metadata: one variant carries the
  TMDB id, another the year, another neither. Variants are matched by
  TMDB id when both sides have one (this also joins localized titles),
  otherwise by normalized title, and only kept apart when there is hard
  evidence they are different works: two distinct TMDB ids or two
  distinct release years. Within a cluster the variant with the richest
  metadata wins.
  """

  @variant_terms ~r/\b(4k|2160p|1080p|720p|hdr10|hdr|dublado|legendado|dual audio|dual-audio|dub|leg|x264|x265|h264|h265|hevc|web-dl|webrip|bluray|blu-ray)\b/iu
  @year_tag ~r/\(\s*((?:19|20)\d{2})\s*\)/u
  @placeholder_titles MapSet.new(["18 xxx"])

  @doc "Empty accumulator for `add/2`."
  @spec new() :: map()
  def new do
    %{cards: %{}, meta: %{}, by_tmdb: %{}, by_title: %{}, next: 0}
  end

  @doc """
  Adds a card, merging it into a matching cluster or starting a new one.
  """
  @spec add(map(), struct()) :: map()
  def add(clusters, item) do
    tmdb = tmdb_id(item)
    year = release_year(item)
    title = normalize_title(item.title || item.name)

    case find_cluster(clusters, tmdb, year, title, reliable_normalized_title?(title)) do
      nil -> start_cluster(clusters, item, tmdb, year, title)
      id -> merge_into(clusters, id, item, tmdb, year, title)
    end
  end

  @doc "Number of canonical cards accumulated so far."
  @spec count(map()) :: non_neg_integer()
  def count(clusters), do: map_size(clusters.cards)

  @doc "All canonical cards, one per cluster."
  @spec cards(map()) :: [struct()]
  def cards(clusters), do: Map.values(clusters.cards)

  @doc "Returns the explicit year or a `(YYYY)` year embedded in the title."
  @spec release_year(struct() | map()) :: integer() | nil
  def release_year(item) do
    case Map.get(item, :year) do
      year when is_integer(year) and year > 0 -> year
      _ -> title_year(Map.get(item, :title)) || title_year(Map.get(item, :name))
    end
  end

  @doc """
  Normalizes a title for variant comparison: strips `[tags]`, `(year)`,
  quality/language markers, punctuation, and casing.
  """
  @spec normalize_title(String.t() | nil) :: String.t()
  def normalize_title(value) when is_binary(value) do
    value
    |> strip_variant_terms()
    |> String.downcase()
  end

  def normalize_title(_), do: ""

  @doc """
  Returns whether a title carries enough identity to match provider variants.

  Some providers expose unrelated entries under a shared placeholder such as
  `+18 XXX`. Those entries must stay independent unless they share a TMDB id.
  """
  @spec reliable_title?(String.t() | nil) :: boolean()
  def reliable_title?(value) do
    value
    |> normalize_title()
    |> reliable_normalized_title?()
  end

  @doc """
  Strips `[tags]`, `(year)`, quality/language markers, and punctuation,
  but keeps the original casing. Used to build trigram search terms.
  """
  @spec strip_variant_terms(String.t() | nil) :: String.t()
  def strip_variant_terms(value) when is_binary(value) do
    value
    |> String.replace(~r/\s*\[[^\]]+\]/u, " ")
    |> String.replace(@year_tag, " ")
    |> String.replace(@variant_terms, " ")
    |> String.replace(~r/[[:punct:]]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def strip_variant_terms(_), do: ""

  # A shared TMDB id always identifies the same work, even across
  # localized titles. Without one, fall back to a title cluster whose
  # accumulated metadata does not contradict the new variant.
  defp find_cluster(clusters, tmdb, year, title, reliable_title?) do
    (tmdb && clusters.by_tmdb[tmdb]) ||
      if reliable_title? do
        Enum.find(clusters.by_title[title] || [], fn id ->
          {cluster_tmdb, cluster_year} = clusters.meta[id]
          same_or_missing(cluster_tmdb, tmdb) and same_or_missing(cluster_year, year)
        end)
      end
  end

  defp start_cluster(clusters, item, tmdb, year, title) do
    id = clusters.next

    %{
      clusters
      | cards: Map.put(clusters.cards, id, item),
        meta: Map.put(clusters.meta, id, {tmdb, year}),
        by_tmdb: index_tmdb(clusters.by_tmdb, tmdb, id),
        by_title: index_title(clusters.by_title, title, id),
        next: id + 1
    }
  end

  defp merge_into(clusters, id, item, tmdb, year, title) do
    {cluster_tmdb, cluster_year} = clusters.meta[id]
    merged_tmdb = cluster_tmdb || tmdb

    %{
      clusters
      | cards: Map.update!(clusters.cards, id, &best_card(&1, item)),
        meta: Map.put(clusters.meta, id, {merged_tmdb, cluster_year || year}),
        by_tmdb: index_tmdb(clusters.by_tmdb, merged_tmdb, id),
        by_title: index_title(clusters.by_title, title, id)
    }
  end

  defp index_tmdb(by_tmdb, nil, _id), do: by_tmdb
  defp index_tmdb(by_tmdb, tmdb, id), do: Map.put_new(by_tmdb, tmdb, id)

  defp index_title(by_title, title, id) do
    Map.update(by_title, title, [id], fn ids ->
      if id in ids, do: ids, else: [id | ids]
    end)
  end

  defp same_or_missing(nil, _), do: true
  defp same_or_missing(_, nil), do: true
  defp same_or_missing(a, b), do: a == b

  defp reliable_normalized_title?(""), do: false
  defp reliable_normalized_title?(title), do: not MapSet.member?(@placeholder_titles, title)

  defp best_card(a, b), do: if(score(b) > score(a), do: b, else: a)

  defp score(item) do
    {
      if(tmdb_id(item), do: 1, else: 0),
      if(release_year(item), do: 1, else: 0),
      numeric_rating(item.rating),
      item.id
    }
  end

  defp tmdb_id(item) do
    case item.tmdb_id do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # A provider that zeroes the `year` column often embeds the real year
  # in the name, e.g. "Evil Island (2023)".
  defp title_year(value) when is_binary(value) do
    case Regex.run(@year_tag, value) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp title_year(_), do: nil

  defp numeric_rating(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_rating(value) when is_number(value), do: value * 1.0
  defp numeric_rating(_), do: 0.0
end
