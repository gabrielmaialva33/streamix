defmodule Streamix.Torrent.Matching do
  @moduledoc """
  Decides whether a scraped release is the catalog movie we are looking for.

  The rules are deliberately conservative because a wrong match puts the
  wrong film behind a poster:

    1. **IMDb first.** When both the wanted movie and the release page carry
       an IMDb id, they must be equal. A different id is a hard "no", even
       when the titles agree (remakes, homonyms).
    2. **Title + year ±1.** Otherwise the normalized title (or original
       title) must be equal and both years must be known and at most one
       year apart (BR sites often date a film by its Brazilian release).

  `prefilter/3` is the cheap pre-check run against search-result snippets
  before any detail page is fetched, so a search for one title does not
  turn into a crawl of every loosely related post.
  """

  @articles ~w(the a an o os as um uma el la los las le les)
  @stopwords ~w(the and of de da do das dos e em no na nos nas com para por um uma o a os as
                el la los las le les du des)

  @type wanted :: %{
          required(:title) => String.t(),
          optional(:original_title) => String.t() | nil,
          optional(:year) => integer() | nil,
          optional(:imdb_id) => String.t() | nil,
          optional(any()) => any()
        }

  @type candidate :: %{
          optional(:title) => String.t() | nil,
          optional(:original_title) => String.t() | nil,
          optional(:year) => integer() | nil,
          optional(:imdb_id) => String.t() | nil,
          optional(any()) => any()
        }

  @doc """
  Returns `{:match, :imdb}`, `{:match, :title_year}` or `:no_match`.
  """
  @spec match(wanted(), candidate()) :: {:match, :imdb | :title_year} | :no_match
  def match(wanted, candidate) do
    wanted_imdb = imdb(Map.get(wanted, :imdb_id))
    candidate_imdb = imdb(Map.get(candidate, :imdb_id))

    cond do
      wanted_imdb && candidate_imdb && wanted_imdb == candidate_imdb -> {:match, :imdb}
      wanted_imdb && candidate_imdb -> :no_match
      title_match?(wanted, candidate) and year_match?(wanted, candidate) -> {:match, :title_year}
      true -> :no_match
    end
  end

  @doc """
  Cheap check on a search-result snippet (URL slug + visible text).

  Passes when most significant words of the wanted title (or original
  title) appear in the snippet and, if the snippet shows years, one of them
  is within ±1 of the wanted year.
  """
  @spec prefilter(wanted(), String.t()) :: boolean()
  def prefilter(wanted, snippet) when is_binary(snippet) do
    tokens = snippet |> normalize() |> String.split(" ", trim: true) |> MapSet.new()

    title_hit? =
      wanted
      |> wanted_titles()
      |> Enum.any?(fn title -> token_coverage(title, tokens) >= 0.75 end)

    title_hit? and snippet_year_ok?(Map.get(wanted, :year), snippet)
  end

  @doc """
  The search query to send for a wanted title: punctuation removed, at most
  six words, so a site's AND-matching search is not defeated by a subtitle
  the site spells differently.
  """
  @spec search_query(String.t()) :: String.t()
  def search_query(title) when is_binary(title) do
    title
    |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.take(6)
    |> Enum.join(" ")
  end

  @doc """
  Whether a title is worth sending to a PT-BR site's text search: mostly
  Latin letters/digits (a CJK title with a stray "II" is not).
  """
  @spec searchable?(String.t() | nil) :: boolean()
  def searchable?(title) when is_binary(title) do
    visible = title |> String.replace(~r/[\s\p{P}\p{S}]+/u, "") |> String.length()
    latin = title |> normalize() |> String.replace(" ", "") |> String.length()

    latin >= 2 and latin * 2 >= visible
  end

  def searchable?(_title), do: false

  @doc """
  Normalized comparison key: lower-case, accents and punctuation removed,
  leading article dropped.
  """
  @spec title_key(String.t() | nil) :: String.t()
  def title_key(nil), do: ""

  def title_key(title) when is_binary(title) do
    case title |> normalize() |> String.split(" ", trim: true) do
      [article, next | rest] when article in @articles -> Enum.join([next | rest], " ")
      words -> Enum.join(words, " ")
    end
  end

  @doc "Lower-case ASCII words separated by single spaces."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> case do
      binary when is_binary(binary) -> binary
      _ -> text
    end
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace("&", " ")
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp title_match?(wanted, candidate) do
    wanted_keys = wanted |> wanted_titles() |> Enum.map(&title_key/1) |> Enum.reject(&(&1 == ""))

    candidate_keys =
      [Map.get(candidate, :title), Map.get(candidate, :original_title)]
      |> Enum.map(&title_key/1)
      |> Enum.reject(&(&1 == ""))

    Enum.any?(wanted_keys, &(&1 in candidate_keys))
  end

  defp year_match?(wanted, candidate) do
    case {Map.get(wanted, :year), Map.get(candidate, :year)} do
      {wanted_year, candidate_year} when is_integer(wanted_year) and is_integer(candidate_year) ->
        abs(wanted_year - candidate_year) <= 1

      _ ->
        false
    end
  end

  defp wanted_titles(wanted) do
    [Map.get(wanted, :title), Map.get(wanted, :original_title)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp token_coverage(title, snippet_tokens) do
    significant =
      title
      |> normalize()
      |> String.split(" ", trim: true)
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.uniq()

    significant =
      if significant == [],
        do: title |> normalize() |> String.split(" ", trim: true),
        else: significant

    case significant do
      [] -> 0.0
      words -> Enum.count(words, &MapSet.member?(snippet_tokens, &1)) / length(words)
    end
  end

  # A snippet without any year (Gratis cards sometimes omit it) cannot rule
  # the candidate out; the detail page will be checked properly.
  defp snippet_year_ok?(year, snippet) when is_integer(year) do
    case Regex.scan(~r/(?<!\d)(?:19|20)\d{2}(?!\d)/, snippet) do
      [] -> true
      years -> Enum.any?(years, fn [y] -> abs(String.to_integer(y) - year) <= 1 end)
    end
  end

  defp snippet_year_ok?(_year, _snippet), do: true

  defp imdb(id) when is_binary(id) do
    case Regex.run(~r/^tt\d{5,12}$/, String.trim(id)) do
      [valid] -> valid
      _ -> nil
    end
  end

  defp imdb(_id), do: nil
end
