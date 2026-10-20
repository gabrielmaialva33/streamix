defmodule Streamix.Iptv.Genres.Vocabulary do
  @moduledoc """
  Closed genre vocabulary. Slugs are stable identities; names are display labels.

  TMDB mappings are scoped to the media type. Combined TV genres expand in
  vocabulary order; TV Movie (10770) is a format and is intentionally omitted.
  """

  @genres [
    {"acao", "Ação", 28, 10_759},
    {"aventura", "Aventura", 12, 10_759},
    {"animacao", "Animação", 16, 16},
    {"comedia", "Comédia", 35, 35},
    {"crime", "Crime", 80, 80},
    {"documentario", "Documentário", 99, 99},
    {"drama", "Drama", 18, 18},
    {"familia", "Família", 10_751, 10_751},
    {"fantasia", "Fantasia", 14, 10_765},
    {"ficcao-cientifica", "Ficção científica", 878, 10_765},
    {"guerra", "Guerra", 10_752, 10_768},
    {"politica", "Política", nil, 10_768},
    {"historia", "História", 36, nil},
    {"terror", "Terror", 27, nil},
    {"suspense", "Suspense", 53, nil},
    {"misterio", "Mistério", 9648, 9648},
    {"musica", "Música", 10_402, nil},
    {"romance", "Romance", 10_749, nil},
    {"faroeste", "Faroeste", 37, 37},
    {"infantil", "Infantil", nil, 10_762},
    {"novela", "Novela", nil, 10_766},
    {"reality", "Reality", nil, 10_764},
    {"talk-show", "Talk show", nil, 10_767},
    {"noticias", "Notícias", nil, 10_763}
  ]

  @all @genres
       |> Enum.with_index(1)
       |> Enum.map(fn {{slug, name, _, _}, position} ->
         %{slug: slug, name: name, position: position}
       end)
  @slugs Enum.map(@all, & &1.slug)
  @names Map.new(@all, &{&1.slug, &1.name})
  @tmdb Map.new([movie: 2, tv: 3], fn {type, index} ->
          mapping =
            @genres
            |> Enum.reject(&is_nil(elem(&1, index)))
            |> Enum.group_by(&elem(&1, index), &elem(&1, 0))
            |> Enum.flat_map(fn {id, slugs} -> [{id, slugs}, {Integer.to_string(id), slugs}] end)
            |> Map.new()

          {type, mapping}
        end)

  @type genre :: %{slug: String.t(), name: String.t(), position: pos_integer()}

  @spec all() :: [genre()]
  def all, do: @all

  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @spec slug?(term()) :: boolean()
  def slug?(slug), do: Map.has_key?(@names, slug)

  @spec name(term()) :: String.t() | nil
  def name(slug), do: Map.get(@names, slug)

  @spec from_tmdb(:movie | :tv, [integer() | String.t()]) :: [String.t()]
  def from_tmdb(type, ids) when type in [:movie, :tv] do
    mapping = Map.fetch!(@tmdb, type)

    ids
    |> Enum.flat_map(&Map.get(mapping, &1, []))
    |> Enum.uniq()
  end
end
