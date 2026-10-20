defmodule Streamix.Iptv.Genres.Normalizer do
  @moduledoc """
  Pure, exact-match normalization of provider genres and category names.

  Adult markers and reels reject the entire input before splitting. Unknown
  tokens are dropped, never guessed or inserted into the closed vocabulary.
  """

  @aliases [
             {"acao", ~w(acao action)},
             {"aventura", ~w(aventura adventure)},
             {"animacao", ~w(animacao animacoes animation anime animes desenho desenhos)},
             {"comedia", ~w(comedia comedy humor)},
             {"crime", ~w(crime policial)},
             {"documentario", ~w(documentario documentarios documentary)},
             {"drama", ~w(drama dramas)},
             {"familia", ~w(familia family)},
             {"fantasia", ~w(fantasia fantasy)},
             {"ficcao-cientifica",
              ["ficcao", "ficcao cientifica", "sci-fi", "scifi", "science fiction"]},
             {"guerra", ~w(guerra war)},
             {"politica", ~w(politica politics)},
             {"historia", ~w(historia history)},
             {"terror", ~w(terror horror)},
             {"suspense", ~w(suspense thriller)},
             {"misterio", ~w(misterio mystery)},
             {"musica", ~w(musica music musical)},
             {"romance", ~w(romance romances romantico)},
             {"faroeste", ~w(faroeste western)},
             {"infantil", ~w(infantil infantis kids criancas)},
             {"novela", ~w(novela novelas telenovela soap)},
             {"reality", ["reality", "reality show"]},
             {"talk-show", ["talk", "talk show"]},
             {"noticias", ~w(noticias news jornalismo)}
           ]
           |> Enum.flat_map(fn {slug, aliases} -> Enum.map([slug | aliases], &{&1, [slug]}) end)
           |> Map.new()
           |> Map.merge(%{
             "action & adventure" => ~w(acao aventura),
             "sci-fi & fantasy" => ~w(ficcao-cientifica fantasia),
             "ficcao & fantasia" => ~w(ficcao-cientifica fantasia),
             "war & politics" => ~w(guerra politica),
             "comedia romantica" => ~w(comedia romance),
             "artes e cultura" => [],
             "cinema tv" => [],
             "mini-dramas" => [],
             "dramas curtos" => []
           })

  @adult ~r/(?:^|[^\p{L}\p{N}_])(?:adultos?|x{3,}|hentai|onlyfans|privacy|brasileirinhas|erotic[oa]s?)(?:$|[^\p{L}\p{N}_])|\+\s*18(?:$|\D)|(?:^|\D)18\s*\+/u
  @reels ~r/(?:^|[^\p{L}\p{N}_])\[reels\]/u
  @decoration ~r/^[\p{P}\p{S}\p{M}\s]+/u
  @shelf_prefix ~r/^(?:filmes|filme|series|canais)\s*[|:]\s*/u
  @separators ~r/[,\/·•|;+]/u
  @conjunctions ~r/\s+(?:&|e|and)\s+/u

  @spec normalize(String.t() | nil) :: [String.t()]
  def normalize(nil), do: []

  def normalize(raw) when is_binary(raw) do
    key = fold(raw)

    if Regex.match?(@adult, key) or Regex.match?(@reels, key) do
      []
    else
      key
      |> strip_decoration()
      |> expand()
      |> Enum.uniq()
    end
  end

  @spec normalize_all([String.t() | nil]) :: [String.t()]
  def normalize_all(values) do
    values
    |> Enum.flat_map(&normalize/1)
    |> Enum.uniq()
  end

  defp fold(raw) do
    raw
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{M}/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp strip_decoration(key) do
    stripped =
      key
      |> String.replace(@decoration, "")
      |> String.replace(@shelf_prefix, "")

    if stripped == key, do: key, else: strip_decoration(stripped)
  end

  # Preserve phrases inside a list before splitting their conjunctions.
  defp expand(key) do
    case Map.fetch(@aliases, key) do
      {:ok, slugs} -> slugs
      :error -> key |> String.split(@separators, trim: true) |> Enum.flat_map(&expand_phrase/1)
    end
  end

  defp expand_phrase(phrase) do
    phrase = String.trim(phrase)

    case Map.fetch(@aliases, phrase) do
      {:ok, slugs} -> slugs
      :error -> phrase |> String.split(@conjunctions, trim: true) |> Enum.flat_map(&lookup/1)
    end
  end

  defp lookup(token), do: Map.get(@aliases, String.trim(token), [])
end
