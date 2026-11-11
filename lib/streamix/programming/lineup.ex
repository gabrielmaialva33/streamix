defmodule Streamix.Programming.Lineup do
  @moduledoc """
  The stations Streamix ships with. Each is a discovery query: the same
  words a viewer could type into "Descobrir".

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

  @doc "The shipped stations, in display order."
  @spec stations() :: [map()]
  def stations do
    @stations
    |> Enum.with_index()
    |> Enum.map(fn {station, position} -> Map.put(station, :position, position) end)
  end
end
