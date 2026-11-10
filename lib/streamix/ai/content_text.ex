defmodule Streamix.AI.ContentText do
  @moduledoc """
  The text a title is embedded as, shared by every embedding provider.

  One labelled line per facet, so a query like "filmes do Nolan" or "terror
  dos anos 80 leve" has something to land on besides the synopsis: genres,
  classified tags (subgenres, mood, pace, era, setting, audience, themes,
  source), TMDB keywords, directors, writers and the billed cast. Lists are capped so a
  long cast does not drown the synopsis. Every facet is optional.
  """

  @people_limit 5
  @keyword_limit 20

  # Classified tag facets (labels), in the order they are written.
  @tag_lines [
    subgenres: "Subgêneros",
    moods: "Clima",
    pace: "Ritmo",
    eras: "Época",
    settings: "Cenário",
    audience: "Público",
    themes: "Temas",
    origins: "Origem"
  ]

  @spec build(map()) :: String.t()
  def build(%{title: title} = content) do
    labels = content[:tag_labels] || %{}
    tag_lines = Enum.map(@tag_lines, fn {facet, label} -> line(label, list(labels[facet])) end)

    ([heading(title, content[:year]), line("Gêneros", list(content[:genres]))] ++
       tag_lines ++
       [
         line("Palavras-chave", content[:keywords] |> list() |> Enum.take(@keyword_limit)),
         line("Direção", content[:directors] |> list() |> Enum.take(@people_limit)),
         line("Roteiro", content[:writers] |> list() |> Enum.take(@people_limit)),
         line("Elenco", content[:cast] |> list() |> Enum.take(@people_limit)),
         text(content[:tagline]),
         text(content[:description]),
         text(content[:plot])
       ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp heading(title, year) when is_integer(year), do: "#{title} (#{year})"
  defp heading(title, _year), do: to_string(title)

  defp line(_label, []), do: nil
  defp line(label, values), do: "#{label}: #{Enum.join(values, ", ")}"

  defp list(values) when is_list(values) do
    values |> Enum.map(&text/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp list(value) when is_binary(value), do: value |> String.split(",") |> list()
  defp list(_value), do: []

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil
end
