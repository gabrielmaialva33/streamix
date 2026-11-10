defmodule Streamix.Iptv.Tags.QueryParser do
  @moduledoc """
  Reads a free-text discovery query ("terror dos anos 80 leve", "comédia
  romântica de natal") into what the catalog can filter and rank on.

  Deterministic and instant, no model call: phrases are matched longest
  first against the genre aliases (`Streamix.Iptv.Genres.Normalizer`), every
  tag label and slug of `Streamix.Iptv.Tags.Vocabulary`, and a short synonym
  list for how people actually type. Decades ("anos 80", "80s", "década de
  1990") become both a release decade and an era tag, since "anos 80" may
  mean either. `:genres` are genres the query names; a matched subgenre's
  genre goes to `:implied_genres` instead, since a time-travel comedy filed
  only as comedy is still a fair answer to "viagem no tempo".

  Whatever matches nothing stays in `:terms`, for the semantic half of the
  search to read.
  """

  alias Streamix.Iptv.Genres.Normalizer
  alias Streamix.Iptv.Genres.Vocabulary, as: GenreVocabulary
  alias Streamix.Iptv.Tags.Vocabulary

  @type t :: %{
          genres: [String.t()],
          implied_genres: [String.t()],
          tags: %{optional(Vocabulary.facet()) => [String.t()]},
          decades: [pos_integer()],
          terms: String.t()
        }

  @max_phrase_words 4

  # How people type it => {facet, slug}. Labels and slugs are matched too;
  # this only adds what they do not cover.
  @synonyms [
    {"zumbis", {:subgenres, "zumbi"}},
    {"zombie", {:subgenres, "zumbi"}},
    {"zombies", {:subgenres, "zumbi"}},
    {"vampiros", {:subgenres, "vampiro"}},
    {"lobisomens", {:subgenres, "lobisomem"}},
    {"exorcismo", {:subgenres, "possessao"}},
    {"demonio", {:subgenres, "possessao"}},
    {"fantasma", {:subgenres, "sobrenatural"}},
    {"fantasmas", {:subgenres, "sobrenatural"}},
    {"assombracao", {:subgenres, "casa-assombrada"}},
    {"heist", {:subgenres, "assalto"}},
    {"roubo", {:subgenres, "assalto"}},
    {"assalto a banco", {:subgenres, "assalto"}},
    {"mafioso", {:subgenres, "mafia"}},
    {"gangster", {:subgenres, "mafia"}},
    {"gangsteres", {:subgenres, "mafia"}},
    {"super heroi", {:subgenres, "super-herois"}},
    {"super herois", {:subgenres, "super-herois"}},
    {"heroi", {:subgenres, "super-herois"}},
    {"herois", {:subgenres, "super-herois"}},
    {"espiao", {:subgenres, "espionagem"}},
    {"espioes", {:subgenres, "espionagem"}},
    {"alienigena", {:subgenres, "invasao-alienigena"}},
    {"alienigenas", {:subgenres, "invasao-alienigena"}},
    {"aliens", {:subgenres, "invasao-alienigena"}},
    {"et", {:subgenres, "invasao-alienigena"}},
    {"robo", {:subgenres, "robos-e-ia"}},
    {"robos", {:subgenres, "robos-e-ia"}},
    {"dinossauro", {:themes, "monstros"}},
    {"dinossauros", {:themes, "monstros"}},
    {"apocalipse", {:subgenres, "pos-apocaliptico"}},
    {"fim do mundo", {:themes, "fim-do-mundo"}},
    {"natalino", {:subgenres, "natal"}},
    {"de natal", {:subgenres, "natal"}},
    {"christmas", {:subgenres, "natal"}},
    {"k drama", {:subgenres, "dorama"}},
    {"kdrama", {:subgenres, "dorama"}},
    {"doramas", {:subgenres, "dorama"}},
    {"novela coreana", {:subgenres, "dorama"}},
    {"animes", {:subgenres, "anime"}},
    {"desenho", {:audience, "infantil"}},
    {"desenhos", {:audience, "infantil"}},
    {"criancas", {:audience, "infantil"}},
    {"crianca", {:audience, "infantil"}},
    {"para criancas", {:audience, "infantil"}},
    {"pra criancas", {:audience, "infantil"}},
    {"para a familia", {:audience, "familia"}},
    {"pra familia", {:audience, "familia"}},
    {"historia real", {:origins, "baseado-em-fatos"}},
    {"fatos reais", {:origins, "baseado-em-fatos"}},
    {"baseado em fatos reais", {:origins, "baseado-em-fatos"}},
    {"baseado em historia real", {:origins, "baseado-em-fatos"}},
    {"baseado em livro", {:origins, "baseado-em-livro"}},
    {"livro", {:origins, "baseado-em-livro"}},
    {"quadrinhos", {:origins, "baseado-em-quadrinhos"}},
    {"hq", {:origins, "baseado-em-quadrinhos"}},
    {"engracados", {:moods, "engracado"}},
    {"divertido", {:moods, "engracado"}},
    {"leves", {:moods, "leve"}},
    {"levinho", {:moods, "leve"}},
    {"de boa", {:moods, "leve"}},
    {"medo", {:moods, "assustador"}},
    {"pesado", {:moods, "perturbador"}},
    {"triste", {:moods, "melancolico"}},
    {"chorar", {:moods, "comovente"}},
    {"emocionante", {:moods, "comovente"}},
    {"adrenalina", {:moods, "eletrizante"}},
    {"romanticos", {:moods, "romantico"}},
    {"espaco sideral", {:settings, "espaco"}},
    {"no espaco", {:settings, "espaco"}},
    {"lento", {:pace, "lento"}},
    {"rapido", {:pace, "acelerado"}},
    {"vinganca", {:themes, "vinganca"}},
    {"ia", {:themes, "inteligencia-artificial"}}
  ]

  @stopwords ~w(a o as os um uma uns umas de do da dos das e ou em no na nos nas com sem para pra
                por sobre que filme filmes serie series algo alguma algum tipo tipo coisa quero ver
                assistir me mostra mostre bom boa bons boas melhor melhores)

  @decade_patterns [
    # "anos 80", "década de 80", "decada 1990", "anos 2000"
    ~r/\b(?:anos|decada(?:\s+de)?)\s+(\d{2}|\d{4})\b/u,
    # "80s", "1980s", "anos80"
    ~r/\b(\d{2}|\d{4})s\b/u
  ]

  @doc "Parses a discovery query; see the module doc."
  @spec parse(String.t() | nil) :: t()
  def parse(query) when is_binary(query) do
    folded = fold(query)
    {decades, rest} = take_decades(folded)
    {matches, leftover} = match_phrases(String.split(rest, " ", trim: true))

    tags =
      matches
      |> Enum.reduce(%{}, fn
        {:genre, _slug}, acc -> acc
        {facet, slug}, acc -> Map.update(acc, facet, [slug], &(&1 ++ [slug]))
      end)
      |> add_decade_eras(decades)
      |> Map.new(fn {facet, slugs} -> {facet, Enum.uniq(slugs)} end)

    genres = for({:genre, slug} <- matches, uniq: true, do: slug)

    implied =
      for {:subgenres, slug} <- matches,
          genre = Vocabulary.subgenre_genre(slug),
          genre not in genres,
          uniq: true,
          do: genre

    %{
      genres: genres,
      implied_genres: implied,
      tags: tags,
      decades: decades,
      terms: leftover |> Enum.reject(&(&1 in @stopwords)) |> Enum.join(" ")
    }
  end

  def parse(_query), do: %{genres: [], implied_genres: [], tags: %{}, decades: [], terms: ""}

  @doc "True when the parse found anything to filter or rank on."
  @spec structured?(t()) :: boolean()
  def structured?(%{genres: genres, tags: tags, decades: decades}),
    do: genres != [] or decades != [] or map_size(tags) > 0

  @doc """
  What the parse understood, as pt-BR labels in reading order: named
  genres, decades, then tags. An era tag that only restates a decade is
  left out.
  """
  @spec labels(t()) :: [String.t()]
  def labels(%{genres: genres, decades: decades, tags: tags}) do
    decade_eras = Enum.flat_map(decades, &List.wrap(era_slug(&1)))

    tag_labels =
      for facet <- Vocabulary.facets(),
          slug <- Map.get(tags, facet, []),
          not (facet == :eras and slug in decade_eras),
          label = Vocabulary.name(facet, slug),
          do: label

    (Enum.flat_map(genres, &List.wrap(GenreVocabulary.name(&1))) ++
       Enum.map(decades, &decade_label/1) ++ tag_labels)
    |> Enum.uniq()
  end

  defp decade_label(decade) when decade >= 2000, do: "Anos #{decade}"
  defp decade_label(decade), do: "Anos #{rem(decade, 100)}"

  # --- Decades ---

  defp take_decades(text) do
    Enum.reduce(@decade_patterns, {[], text}, fn pattern, {decades, text} ->
      found =
        pattern
        |> Regex.scan(text)
        |> Enum.flat_map(fn [_, digits] -> List.wrap(decade(digits)) end)

      {decades ++ found, Regex.replace(pattern, text, " ")}
    end)
    |> then(fn {decades, text} -> {Enum.uniq(decades), text} end)
  end

  defp decade(digits) do
    case Integer.parse(digits) do
      {n, ""} when n in [20, 30, 40, 50, 60, 70, 80, 90] -> 1900 + n
      {n, ""} when n >= 1900 and n <= 2020 and rem(n, 10) == 0 -> n
      _other -> nil
    end
  end

  defp add_decade_eras(tags, []), do: tags

  defp add_decade_eras(tags, decades) do
    eras = Enum.flat_map(decades, &List.wrap(era_slug(&1)))
    if eras == [], do: tags, else: Map.update(tags, :eras, eras, &(&1 ++ eras))
  end

  defp era_slug(decade) when decade in [1900, 1910, 1920], do: "anos-1900-1920"

  defp era_slug(decade) do
    slug = "anos-#{decade}"
    if Vocabulary.name(:eras, slug), do: slug
  end

  # --- Phrases ---

  # Longest phrase first at each position; unmatched words are left over.
  defp match_phrases(words), do: match_phrases(words, [], [])

  defp match_phrases([], matches, leftover), do: {Enum.reverse(matches), Enum.reverse(leftover)}

  defp match_phrases(words, matches, leftover) do
    longest = min(@max_phrase_words, length(words))

    found =
      Enum.find_value(longest..1//-1, fn size ->
        phrase = words |> Enum.take(size) |> Enum.join(" ")

        case lookup(phrase) do
          [] -> nil
          hits -> {size, hits}
        end
      end)

    case found do
      {size, hits} ->
        match_phrases(Enum.drop(words, size), Enum.reverse(hits) ++ matches, leftover)

      nil ->
        match_phrases(tl(words), matches, [hd(words) | leftover])
    end
  end

  # A phrase can be a genre and a tag at once ("família", "música").
  defp lookup(phrase), do: Map.get(dictionary(), phrase, []) ++ genre_hits(phrase)

  # Single stopwords never count as a genre ("de" is not a shelf).
  defp genre_hits(phrase) do
    if phrase in @stopwords,
      do: [],
      else: phrase |> Normalizer.normalize() |> Enum.map(&{:genre, &1})
  end

  defp dictionary do
    case :persistent_term.get({__MODULE__, :dictionary, Vocabulary.version()}, nil) do
      nil ->
        dictionary = build_dictionary()
        :persistent_term.put({__MODULE__, :dictionary, Vocabulary.version()}, dictionary)
        dictionary

      dictionary ->
        dictionary
    end
  end

  defp build_dictionary do
    vocabulary =
      for facet <- Vocabulary.facets(),
          {slug, name} <- Vocabulary.entries(facet),
          phrase <- [fold(name), slug |> String.replace("-", " ") |> fold()],
          phrase != "",
          do: {phrase, {facet, slug}}

    (vocabulary ++ Enum.map(@synonyms, fn {phrase, hit} -> {fold(phrase), hit} end))
    |> Enum.reject(fn {phrase, _hit} -> phrase in @stopwords end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {phrase, hits} -> {phrase, Enum.uniq(hits)} end)
  end

  defp fold(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end
end
