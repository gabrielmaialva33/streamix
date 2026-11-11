defmodule Streamix.Programming.Lineup do
  @moduledoc """
  The stations Streamix ships with. A movie station is a discovery query,
  the same words a viewer could type into "Descobrir"; a series station is
  a list of TMDB series whose episodes play in random order.

  `Streamix.Programming.sync_lineup/0` creates missing ones and refreshes the
  name, description, query and order of existing ones; a station removed
  from this list is deactivated, never deleted.
  """

  @stations [
    %{
      slug: "terror-anos-80",
      name: "Terror Anos 80",
      description: "Slashers, possessões e criaturas da década mais sangrenta.",
      query: "terror anos 80"
    },
    %{
      slug: "comedia-romantica",
      name: "Comédia Romântica",
      description: "Amores improváveis e finais felizes, sem pressa.",
      query: "comédia romântica leve"
    },
    %{
      slug: "acao-sem-parar",
      name: "Ação Sem Parar",
      description: "Perseguição, tiroteio e explosão, um atrás do outro.",
      query: "ação eletrizante"
    },
    %{
      slug: "ficcao-cientifica",
      name: "Ficção Científica",
      description: "Espaço, futuro, viagem no tempo e o que dá errado nisso.",
      query: "ficção científica espaço futuro"
    },
    %{
      slug: "suspense",
      name: "Suspense",
      description: "Thrillers psicológicos para roer as unhas.",
      query: "thriller psicológico tenso"
    },
    %{
      slug: "crime-e-mafia",
      name: "Crime e Máfia",
      description: "Gângsteres, assaltos e detetives.",
      query: "filmes de máfia crime organizado assalto"
    },
    %{
      slug: "animacao-em-familia",
      name: "Animação em Família",
      description: "Para ver com as crianças (e sem elas).",
      query: "animação para a família"
    },
    %{
      slug: "baseado-em-fatos",
      name: "Baseado em Fatos",
      description: "Histórias reais que parecem inventadas.",
      query: "baseado em fatos reais drama"
    }
  ]

  # Series stations name their series by TMDB id, so any provider's copy
  # counts. One id: that show around the clock; several: a marathon.
  @series_stations [
    {"chaves", "Chaves 24h", "Foi sem querer querendo.", ["47"]},
    {"chapolin", "Chapolin 24h", "Não contavam com a minha astúcia!", ["13023"]},
    {"os-simpsons", "Os Simpsons 24h", "Springfield sem intervalo.", ["456"]},
    {"friends", "Friends 24h", "Os seis no Central Perk, o dia todo.", ["1668"]},
    {"todo-mundo-odeia-o-chris", "Todo Mundo Odeia o Chris 24h", "Brooklyn, 1982.", ["252"]},
    {"eu-a-patroa-e-as-criancas", "Eu, a Patroa e as Crianças 24h", "Michael Kyle em família.",
     ["2692"]},
    {"dois-homens-e-meio", "Dois Homens e Meio 24h", "Charlie, Alan e Jake.", ["2691"]},
    {"the-office", "The Office 24h", "Um dia normal na Dunder Mifflin.", ["2316"]},
    {"big-bang", "Big Bang 24h", "Bazinga.", ["1418"]},
    {"bob-esponja", "Bob Esponja 24h", "Direto da Fenda do Biquíni.", ["387"]},
    {"scooby-doo", "Scooby-Doo 24h", "Mistérios e biscoitos Scooby.", ["926"]},
    {"maratona-sitcom", "Maratona de Sitcom", "Episódios aleatórios das sitcoms favoritas.",
     ["1668", "1418", "2316", "2691", "2692", "252", "1421", "1400"]},
    {"animacao-adulta", "Animação Adulta", "Simpsons, South Park, Rick e Morty e companhia.",
     ["456", "2190", "60625", "1434", "32726"]}
  ]

  @doc "The shipped stations, in display order: movie stations, then series."
  @spec stations() :: [map()]
  def stations do
    movies = Enum.map(@stations, &Map.merge(&1, %{kind: "movies", series_tmdb_ids: []}))

    series =
      Enum.map(@series_stations, fn {slug, name, description, tmdb_ids} ->
        %{
          slug: slug,
          name: name,
          description: description,
          query: name,
          kind: "series",
          series_tmdb_ids: tmdb_ids
        }
      end)

    (movies ++ series)
    |> Enum.with_index()
    |> Enum.map(fn {station, position} -> Map.put(station, :position, position) end)
  end
end
