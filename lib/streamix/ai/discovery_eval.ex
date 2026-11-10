defmodule Streamix.AI.DiscoveryEval do
  @moduledoc """
  A fixed set of discovery queries with objective relevance checks, to tell
  whether a search change made results better or only different.

  A result is relevant when it passes every check group of its query, a
  group passing when any of its conditions holds against the title's
  catalog facts (genres, year, credits, TMDB keywords, tags). The score is
  precision at 10: relevant results among the first ten, missing results
  counting as misses.

      Streamix.AI.DiscoveryEval.run(:baseline)  # plain semantic search
      Streamix.AI.DiscoveryEval.run(:discover)  # Streamix.AI.Discovery

  Each query embeds once, so a run paces itself to the embedding API's
  per-minute limit (`:delay_ms`, default 1_600).
  """

  alias Streamix.AI.{Discovery, SemanticSearch}
  alias Streamix.Search

  @k 10

  @queries [
    {"terror anos 80", [[{:genre, "Terror"}], [{:year, 1980, 1989}, {:tag, :eras, "anos-1980"}]]},
    {"filmes do christopher nolan", [[{:director, "christopher nolan"}]]},
    {"filmes do quentin tarantino", [[{:director, "quentin tarantino"}]]},
    {"tom hanks", [[{:cast, "tom hanks"}]]},
    {"leonardo dicaprio", [[{:cast, "leonardo dicaprio"}]]},
    {"zumbis", [[{:keyword, "zombie"}, {:tag, :subgenres, "zumbi"}]]},
    {"filme de vampiro", [[{:keyword, "vampire"}, {:tag, :subgenres, "vampiro"}]]},
    {"filme de tubarão", [[{:keyword, "shark"}]]},
    {"dinossauros", [[{:keyword, "dinosaur"}]]},
    {"viagem no tempo",
     [
       [
         {:keyword, "time travel"},
         {:tag, :subgenres, "viagem-no-tempo"},
         {:tag, :themes, "viagem-no-tempo"}
       ]
     ]},
    {"assalto a banco",
     [[{:keyword, "heist"}, {:keyword, "bank robbery"}, {:tag, :subgenres, "assalto"}]]},
    {"serial killer", [[{:keyword, "serial killer"}, {:tag, :subgenres, "serial-killer"}]]},
    {"filmes de máfia",
     [[{:keyword, "mafia"}, {:keyword, "gangster"}, {:tag, :subgenres, "mafia"}]]},
    {"super-heróis", [[{:keyword, "superhero"}, {:tag, :subgenres, "super-herois"}]]},
    {"invasão alienígena",
     [[{:keyword, "alien invasion"}, {:tag, :subgenres, "invasao-alienigena"}]]},
    {"pós-apocalíptico",
     [[{:keyword, "post-apocalyptic"}, {:tag, :subgenres, "pos-apocaliptico"}]]},
    {"segunda guerra mundial",
     [[{:keyword, "world war ii"}, {:tag, :subgenres, "segunda-guerra"}]]},
    {"possessão demoníaca",
     [
       [{:genre, "Terror"}],
       [{:keyword, "possession"}, {:keyword, "exorcism"}, {:tag, :subgenres, "possessao"}]
     ]},
    {"casa assombrada", [[{:keyword, "haunted house"}, {:tag, :subgenres, "casa-assombrada"}]]},
    {"inteligência artificial",
     [
       [
         {:keyword, "artificial intelligence"},
         {:tag, :themes, "inteligencia-artificial"},
         {:tag, :subgenres, "robos-e-ia"}
       ]
     ]},
    {"filme de boxe", [[{:keyword, "boxing"}]]},
    {"comédia romântica de natal",
     [
       [{:keyword, "christmas"}, {:tag, :subgenres, "natal"}],
       [{:genre, "Romance"}, {:genre, "Comédia"}]
     ]},
    {"comédia dos anos 90",
     [[{:genre, "Comédia"}], [{:year, 1990, 1999}, {:tag, :eras, "anos-1990"}]]},
    {"animação para crianças",
     [
       [{:genre, "Animação"}],
       [{:genre, "Família"}, {:tag, :audience, "infantil"}, {:tag, :audience, "familia"}]
     ]},
    {"documentário sobre música",
     [[{:genre, "Documentário"}], [{:keyword, "music"}, {:tag, :subgenres, "doc-musica"}]]},
    {"faroeste", [[{:genre, "Faroeste"}]]},
    {"ficção científica no espaço",
     [[{:genre, "Ficção científica"}], [{:keyword, "space"}, {:tag, :settings, "espaco"}]]},
    {"baseado em fatos reais",
     [
       [
         {:keyword, "based on true story"},
         {:keyword, "biography"},
         {:tag, :origins, "baseado-em-fatos"}
       ]
     ]},
    {"baseado em livro", [[{:keyword, "based on novel"}, {:tag, :origins, "baseado-em-livro"}]]},
    {"slasher", [[{:keyword, "slasher"}, {:tag, :subgenres, "slasher"}]]}
  ]

  @doc "The queries and their checks."
  def queries, do: @queries

  @doc """
  Runs every query in `mode` (`:baseline` or `:discover`) over movies and
  returns the mean precision@#{@k} and each query's score.
  """
  @spec run(:baseline | :discover, keyword()) :: %{precision: float(), queries: list()}
  def run(mode, opts \\ []) when mode in [:baseline, :discover] do
    delay = Keyword.get(opts, :delay_ms, 1_600)

    scored =
      @queries
      |> Enum.with_index()
      |> Enum.map(fn {{query, checks}, index} ->
        if index > 0 and delay > 0, do: Process.sleep(delay)
        score(query, checks, ids(mode, query))
      end)

    %{
      precision: mean(Enum.map(scored, & &1.precision)),
      queries: scored
    }
  end

  defp ids(:baseline, query) do
    case SemanticSearch.search(query, :movies, limit: @k * 3) do
      {:ok, results} -> results |> Enum.map(& &1.id) |> Enum.take(@k)
      {:error, _reason} -> []
    end
  end

  defp ids(:discover, query) do
    case Discovery.discover(query, :movies, limit: @k) do
      {:ok, %{results: results}} -> Enum.map(results, & &1.id)
      {:error, _reason} -> []
    end
  end

  @doc false
  def score(query, checks, ids) do
    documents = :movies |> Search.search_documents_for_ids(ids) |> Map.new(&{&1.id, &1})

    hits =
      Enum.map(ids, fn id ->
        doc = Map.get(documents, id)
        {doc && doc.title, doc != nil and relevant?(doc, checks)}
      end)

    relevant = Enum.count(hits, &elem(&1, 1))

    %{
      query: query,
      precision: relevant / @k,
      relevant: relevant,
      returned: length(ids),
      misses: for({title, false} <- hits, do: title)
    }
  end

  @doc false
  def relevant?(doc, checks),
    do: Enum.all?(checks, fn group -> Enum.any?(group, &holds?(doc, &1)) end)

  defp holds?(doc, {:genre, name}), do: String.contains?(doc.genres || "", name)

  defp holds?(doc, {:year, from, to}),
    do: is_integer(doc.year) and doc.year >= from and doc.year <= to

  defp holds?(doc, {:director, name}), do: person?(doc.directors, name)
  defp holds?(doc, {:cast, name}), do: person?(doc.cast, name)

  defp holds?(doc, {:keyword, word}),
    do: Enum.any?(doc.keywords || [], &String.contains?(String.downcase(&1), word))

  defp holds?(doc, {:tag, facet, slug}) do
    case doc.tags do
      %{} = tags -> slug in List.wrap(Map.get(tags, facet))
      nil -> false
    end
  end

  defp person?(people, name), do: Enum.any?(people || [], &(String.downcase(&1) == name))

  defp mean([]), do: 0.0
  defp mean(values), do: Float.round(Enum.sum(values) / length(values), 3)
end
