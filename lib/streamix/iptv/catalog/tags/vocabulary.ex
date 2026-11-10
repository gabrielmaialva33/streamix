defmodule Streamix.Iptv.Tags.Vocabulary do
  @moduledoc """
  The closed tag vocabulary a title is classified into, one facet at a time.

  The 24 canonical genres (`Streamix.Iptv.Genres.Vocabulary`) say what shelf a
  title sits on; these facets say what it is like: its subgenres, how it
  feels, how fast it moves, when and where it is set, who it is for, what it
  is about and what it was adapted from.

  Slugs are stable identities (stored, filtered on, sent to the classifier
  as an enum); labels are pt-BR display text. Every subgenre names the
  canonical genre it refines. `version/0` changes whenever a slug is added,
  removed or redefined, so titles classified against an older vocabulary can
  be found and classified again.

  `era` is when the story takes place, not when the title was released: the
  release decade already comes from `year`.
  """

  @version 1

  @subgenres [
    # Ação
    {"artes-marciais", "Artes marciais", "acao"},
    {"espionagem", "Espionagem", "acao"},
    {"super-herois", "Super-heróis", "acao"},
    {"acao-militar", "Ação militar", "acao"},
    {"perseguicao", "Perseguição e carros", "acao"},
    {"dupla-policial", "Dupla policial", "acao"},
    {"catastrofe", "Filme-catástrofe", "acao"},
    {"sobrevivencia", "Sobrevivência", "acao"},
    # Aventura
    {"aventura-epica", "Aventura épica", "aventura"},
    {"caca-ao-tesouro", "Caça ao tesouro", "aventura"},
    {"exploracao", "Exploração", "aventura"},
    {"piratas", "Piratas", "aventura"},
    {"capa-e-espada", "Capa e espada", "aventura"},
    {"road-movie", "Road movie", "aventura"},
    # Animação
    {"anime", "Anime", "animacao"},
    {"animacao-adulta", "Animação adulta", "animacao"},
    {"stop-motion", "Stop-motion", "animacao"},
    {"shonen", "Shōnen", "animacao"},
    {"shojo", "Shōjo", "animacao"},
    {"seinen", "Seinen", "animacao"},
    {"isekai", "Isekai", "animacao"},
    {"mecha", "Mecha", "animacao"},
    {"cotidiano", "Cotidiano (slice of life)", "animacao"},
    # Comédia
    {"comedia-romantica", "Comédia romântica", "comedia"},
    {"pastelao", "Pastelão", "comedia"},
    {"satira", "Sátira", "comedia"},
    {"parodia", "Paródia", "comedia"},
    {"humor-negro", "Humor negro", "comedia"},
    {"comedia-de-costumes", "Comédia de costumes", "comedia"},
    {"comedia-adolescente", "Comédia adolescente", "comedia"},
    {"besteirol", "Besteirol", "comedia"},
    {"comedia-de-acao", "Comédia de ação", "comedia"},
    {"sitcom", "Sitcom", "comedia"},
    {"stand-up", "Stand-up", "comedia"},
    {"falso-documentario", "Falso documentário", "comedia"},
    # Crime
    {"procedural-policial", "Procedural policial", "crime"},
    {"mafia", "Máfia e gângsteres", "crime"},
    {"assalto", "Assalto (heist)", "crime"},
    {"golpe", "Golpistas", "crime"},
    {"noir", "Noir", "crime"},
    {"neo-noir", "Neo-noir", "crime"},
    {"serial-killer", "Serial killer", "crime"},
    {"narcotrafico", "Narcotráfico", "crime"},
    {"detetive", "Detetive", "crime"},
    {"filme-de-prisao", "Filme de prisão", "crime"},
    {"drama-de-tribunal", "Drama de tribunal", "crime"},
    # Documentário
    {"doc-natureza", "Natureza e vida selvagem", "documentario"},
    {"doc-true-crime", "True crime", "documentario"},
    {"doc-esporte", "Documentário esportivo", "documentario"},
    {"doc-musica", "Documentário musical", "documentario"},
    {"doc-historia", "Documentário histórico", "documentario"},
    {"doc-ciencia", "Ciência e tecnologia", "documentario"},
    {"doc-biografia", "Documentário biográfico", "documentario"},
    {"doc-sociedade", "Sociedade e política", "documentario"},
    {"doc-gastronomia", "Gastronomia", "documentario"},
    {"doc-viagem", "Viagem e culturas", "documentario"},
    # Drama
    {"drama-familiar", "Drama familiar", "drama"},
    {"drama-de-epoca", "Drama de época", "drama"},
    {"cinebiografia", "Cinebiografia", "drama"},
    {"drama-esportivo", "Drama esportivo", "drama"},
    {"drama-medico", "Drama médico", "drama"},
    {"drama-psicologico", "Drama psicológico", "drama"},
    {"drama-social", "Drama social", "drama"},
    {"melodrama", "Melodrama", "drama"},
    {"amadurecimento", "Amadurecimento (coming-of-age)", "drama"},
    {"drama-adolescente", "Drama adolescente", "drama"},
    {"drama-lgbtqia", "Drama LGBTQIA+", "drama"},
    {"drama-de-guerra", "Drama de guerra", "drama"},
    # Família
    {"natal", "Natal e festas", "familia"},
    {"aventura-familiar", "Aventura familiar", "familia"},
    {"filme-de-animal", "Filme de animal", "familia"},
    # Fantasia
    {"alta-fantasia", "Alta fantasia", "fantasia"},
    {"fantasia-urbana", "Fantasia urbana", "fantasia"},
    {"conto-de-fadas", "Conto de fadas", "fantasia"},
    {"fantasia-sombria", "Fantasia sombria", "fantasia"},
    {"mitologia", "Mitologia", "fantasia"},
    {"realismo-magico", "Realismo mágico", "fantasia"},
    {"bruxaria", "Bruxaria e magia", "fantasia"},
    # Ficção científica
    {"space-opera", "Space opera", "ficcao-cientifica"},
    {"cyberpunk", "Cyberpunk", "ficcao-cientifica"},
    {"distopia", "Distopia", "ficcao-cientifica"},
    {"pos-apocaliptico", "Pós-apocalíptico", "ficcao-cientifica"},
    {"viagem-no-tempo", "Viagem no tempo", "ficcao-cientifica"},
    {"invasao-alienigena", "Invasão alienígena", "ficcao-cientifica"},
    {"primeiro-contato", "Primeiro contato", "ficcao-cientifica"},
    {"robos-e-ia", "Robôs e IA", "ficcao-cientifica"},
    {"ficcao-hard", "Ficção científica hard", "ficcao-cientifica"},
    {"kaiju", "Kaiju e monstros gigantes", "ficcao-cientifica"},
    {"multiverso", "Multiverso", "ficcao-cientifica"},
    {"experimento-cientifico", "Experimento que deu errado", "ficcao-cientifica"},
    # Guerra
    {"segunda-guerra", "Segunda Guerra Mundial", "guerra"},
    {"primeira-guerra", "Primeira Guerra Mundial", "guerra"},
    {"guerra-do-vietna", "Guerra do Vietnã", "guerra"},
    {"guerra-moderna", "Guerra moderna", "guerra"},
    {"guerra-fria", "Guerra Fria", "guerra"},
    # História
    {"epico-historico", "Épico histórico", "historia"},
    {"realeza", "Realeza e corte", "historia"},
    # Terror
    {"slasher", "Slasher", "terror"},
    {"sobrenatural", "Sobrenatural", "terror"},
    {"possessao", "Possessão e exorcismo", "terror"},
    {"casa-assombrada", "Casa assombrada", "terror"},
    {"found-footage", "Found footage", "terror"},
    {"zumbi", "Zumbi", "terror"},
    {"vampiro", "Vampiro", "terror"},
    {"lobisomem", "Lobisomem", "terror"},
    {"folk-horror", "Folk horror", "terror"},
    {"body-horror", "Body horror", "terror"},
    {"terror-psicologico", "Terror psicológico", "terror"},
    {"terror-comico", "Terror cômico", "terror"},
    {"criatura", "Criatura", "terror"},
    {"invasao-domiciliar", "Invasão domiciliar", "terror"},
    {"terror-cosmico", "Terror cósmico", "terror"},
    {"seita", "Seitas e cultos", "terror"},
    {"terror-asiatico", "Terror asiático", "terror"},
    {"giallo", "Giallo", "terror"},
    # Suspense
    {"thriller-psicologico", "Thriller psicológico", "suspense"},
    {"conspiracao", "Conspiração", "suspense"},
    {"thriller-erotico", "Thriller erótico", "suspense"},
    {"thriller-tecnologico", "Thriller tecnológico", "suspense"},
    {"sequestro", "Sequestro", "suspense"},
    {"thriller-juridico", "Thriller jurídico", "suspense"},
    # Mistério
    {"quem-matou", "Quem matou? (whodunit)", "misterio"},
    {"quebra-cabeca", "Narrativa quebra-cabeça", "misterio"},
    # Música
    {"musical", "Musical", "musica"},
    {"cinebiografia-musical", "Cinebiografia musical", "musica"},
    {"show", "Show e concerto", "musica"},
    {"filme-de-danca", "Filme de dança", "musica"},
    # Romance
    {"romance-de-epoca", "Romance de época", "romance"},
    {"romance-adolescente", "Romance adolescente", "romance"},
    {"romance-tragico", "Romance trágico", "romance"},
    {"romance-lgbtqia", "Romance LGBTQIA+", "romance"},
    # Faroeste
    {"western-classico", "Faroeste clássico", "faroeste"},
    {"spaghetti-western", "Spaghetti western", "faroeste"},
    {"neo-western", "Neo-faroeste", "faroeste"},
    # Infantil
    {"pre-escolar", "Pré-escolar", "infantil"},
    {"desenho-classico", "Desenho clássico", "infantil"},
    # Novela
    {"novela-brasileira", "Novela brasileira", "novela"},
    {"novela-latina", "Novela latina", "novela"},
    {"novela-turca", "Novela turca", "novela"},
    {"dorama", "Dorama (K-drama)", "novela"},
    {"novela-biblica", "Novela bíblica", "novela"},
    # Reality
    {"reality-de-competicao", "Reality de competição", "reality"},
    {"reality-de-namoro", "Reality de namoro", "reality"},
    {"reality-culinario", "Reality culinário", "reality"},
    {"reality-de-confinamento", "Reality de confinamento", "reality"}
  ]

  @moods [
    {"sombrio", "Sombrio"},
    {"tenso", "Tenso"},
    {"assustador", "Assustador"},
    {"perturbador", "Perturbador"},
    {"engracado", "Engraçado"},
    {"leve", "Leve"},
    {"aconchegante", "Aconchegante"},
    {"romantico", "Romântico"},
    {"comovente", "Comovente"},
    {"eletrizante", "Eletrizante"},
    {"inspirador", "Inspirador"},
    {"melancolico", "Melancólico"},
    {"nostalgico", "Nostálgico"},
    {"epico", "Épico"},
    {"misterioso", "Misterioso"},
    {"reflexivo", "Reflexivo"},
    {"absurdo", "Absurdo"},
    {"sensual", "Sensual"}
  ]

  @paces [
    {"lento", "Lento"},
    {"moderado", "Moderado"},
    {"acelerado", "Acelerado"}
  ]

  @eras [
    {"pre-historia", "Pré-história"},
    {"antiguidade", "Antiguidade"},
    {"idade-media", "Idade Média"},
    {"seculos-16-18", "Séculos XVI a XVIII"},
    {"seculo-19", "Século XIX"},
    {"anos-1900-1920", "Início do século XX"},
    {"anos-1930", "Anos 30"},
    {"anos-1940", "Anos 40"},
    {"anos-1950", "Anos 50"},
    {"anos-1960", "Anos 60"},
    {"anos-1970", "Anos 70"},
    {"anos-1980", "Anos 80"},
    {"anos-1990", "Anos 90"},
    {"anos-2000", "Anos 2000"},
    {"anos-2010", "Anos 2010"},
    {"atualidade", "Atualidade"},
    {"futuro-proximo", "Futuro próximo"},
    {"futuro-distante", "Futuro distante"},
    {"atemporal", "Atemporal ou mundo inventado"}
  ]

  @settings [
    {"cidade-grande", "Cidade grande"},
    {"cidade-pequena", "Cidade pequena"},
    {"suburbio", "Subúrbio"},
    {"campo", "Campo e fazenda"},
    {"deserto", "Deserto"},
    {"selva", "Selva e floresta"},
    {"neve", "Neve e montanha"},
    {"mar", "Mar e navios"},
    {"ilha", "Ilha e praia"},
    {"espaco", "Espaço"},
    {"outro-planeta", "Outro planeta"},
    {"mundo-de-fantasia", "Mundo de fantasia"},
    {"mundo-virtual", "Mundo virtual"},
    {"escola", "Escola"},
    {"universidade", "Universidade"},
    {"hospital", "Hospital"},
    {"prisao", "Prisão"},
    {"escritorio", "Escritório"},
    {"campo-de-batalha", "Campo de batalha"},
    {"estrada", "Estrada"},
    {"lugar-confinado", "Lugar confinado"},
    {"favela", "Favela e periferia"}
  ]

  @audiences [
    {"infantil", "Infantil"},
    {"familia", "Família"},
    {"adolescente", "Adolescente"},
    {"adulto", "Adulto"},
    {"adulto-pesado", "Adulto (violência ou sexo explícitos)"}
  ]

  @themes [
    {"vinganca", "Vingança"},
    {"amizade", "Amizade"},
    {"familia", "Família"},
    {"amor", "Amor"},
    {"primeiro-amor", "Primeiro amor"},
    {"casamento", "Casamento e divórcio"},
    {"maternidade-paternidade", "Maternidade e paternidade"},
    {"infancia", "Infância"},
    {"envelhecimento", "Envelhecimento"},
    {"luto", "Luto"},
    {"superacao", "Superação"},
    {"redencao", "Redenção"},
    {"sacrificio", "Sacrifício"},
    {"traicao", "Traição"},
    {"ganancia", "Ganância"},
    {"poder-e-corrupcao", "Poder e corrupção"},
    {"justica", "Justiça"},
    {"identidade", "Identidade"},
    {"solidao", "Solidão"},
    {"saude-mental", "Saúde mental"},
    {"vicio", "Vício"},
    {"obsessao", "Obsessão"},
    {"ciume", "Ciúme"},
    {"sexualidade", "Sexualidade"},
    {"lgbtqia", "LGBTQIA+"},
    {"genero-e-feminismo", "Gênero e feminismo"},
    {"racismo", "Racismo"},
    {"desigualdade", "Desigualdade social"},
    {"imigracao", "Imigração"},
    {"religiao", "Religião e fé"},
    {"guerra", "Guerra"},
    {"crime-organizado", "Crime organizado"},
    {"policia", "Polícia"},
    {"politica", "Política"},
    {"rebeliao", "Rebelião e resistência"},
    {"escravidao", "Escravidão"},
    {"holocausto", "Holocausto"},
    {"colonialismo", "Colonialismo"},
    {"tecnologia", "Tecnologia"},
    {"inteligencia-artificial", "Inteligência artificial"},
    {"hackers", "Hackers"},
    {"viagem-no-tempo", "Viagem no tempo"},
    {"fim-do-mundo", "Fim do mundo"},
    {"alienigenas", "Alienígenas"},
    {"monstros", "Monstros"},
    {"magia", "Magia"},
    {"natureza", "Natureza e meio ambiente"},
    {"animais", "Animais"},
    {"esporte", "Esporte"},
    {"musica", "Música"},
    {"arte", "Arte"},
    {"comida", "Comida"},
    {"viagem", "Viagem"},
    {"escola", "Escola"},
    {"trabalho", "Trabalho"},
    {"dinheiro", "Dinheiro"},
    {"segredos", "Segredos"},
    {"assassinato", "Assassinato"},
    {"sequestro", "Sequestro"},
    {"conspiracao", "Conspiração"},
    {"fama", "Fama e mídia"},
    {"sobrevivencia", "Sobrevivência"},
    {"liberdade", "Liberdade"},
    {"honra", "Honra"}
  ]

  @origins [
    {"baseado-em-fatos", "Baseado em fatos reais"},
    {"baseado-em-livro", "Baseado em livro"},
    {"baseado-em-quadrinhos", "Baseado em quadrinhos"},
    {"baseado-em-manga", "Baseado em mangá ou anime"},
    {"baseado-em-jogo", "Baseado em videogame"},
    {"baseado-em-peca", "Baseado em peça de teatro"},
    {"remake", "Remake"},
    {"sequencia", "Sequência"},
    {"spin-off", "Spin-off"},
    {"antologia", "Antologia"},
    {"minisserie", "Minissérie"}
  ]

  # facet => {entries, how many a title may carry}
  @facets %{
    subgenres: {Enum.map(@subgenres, fn {slug, name, _genre} -> {slug, name} end), 4},
    moods: {@moods, 3},
    pace: {@paces, 1},
    eras: {@eras, 2},
    settings: {@settings, 3},
    audience: {@audiences, 1},
    themes: {@themes, 6},
    origins: {@origins, 3}
  }

  @facet_order [:subgenres, :moods, :pace, :eras, :settings, :audience, :themes, :origins]
  @single [:pace, :audience]

  @names Map.new(@facets, fn {facet, {entries, _}} -> {facet, Map.new(entries)} end)
  @slugs Map.new(@facets, fn {facet, {entries, _}} -> {facet, Enum.map(entries, &elem(&1, 0))} end)
  @subgenre_genres Map.new(@subgenres, fn {slug, _name, genre} -> {slug, genre} end)

  @type facet ::
          :subgenres | :moods | :pace | :eras | :settings | :audience | :themes | :origins

  @doc "Bumped whenever a slug is added, removed or redefined."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Facets in display order."
  @spec facets() :: [facet()]
  def facets, do: @facet_order

  @doc "Facets that hold exactly one slug instead of a list."
  @spec single?(facet()) :: boolean()
  def single?(facet), do: facet in @single

  @doc "How many slugs a title may carry in a facet."
  @spec limit(facet()) :: pos_integer()
  def limit(facet), do: @facets |> Map.fetch!(facet) |> elem(1)

  @doc "Every slug of a facet, in vocabulary order."
  @spec slugs(facet()) :: [String.t()]
  def slugs(facet), do: Map.fetch!(@slugs, facet)

  @doc "`{slug, label}` pairs of a facet, in vocabulary order."
  @spec entries(facet()) :: [{String.t(), String.t()}]
  def entries(facet), do: @facets |> Map.fetch!(facet) |> elem(0)

  @doc "The pt-BR label of a slug in a facet, or nil."
  @spec name(facet(), term()) :: String.t() | nil
  def name(facet, slug), do: @names |> Map.fetch!(facet) |> Map.get(slug)

  @doc "The canonical genre slug a subgenre refines."
  @spec subgenre_genre(String.t()) :: String.t() | nil
  def subgenre_genre(slug), do: Map.get(@subgenre_genres, slug)

  @doc """
  The whole vocabulary as data, for code outside the catalog (the
  classifier): each facet with its limit, whether it holds one slug, and its
  `{slug, label, genre}` entries (`genre` is the refined canonical genre for
  subgenres, nil elsewhere).
  """
  @spec describe() :: [
          %{
            facet: facet(),
            limit: pos_integer(),
            single: boolean(),
            entries: [{String.t(), String.t(), String.t() | nil}]
          }
        ]
  def describe do
    Enum.map(@facet_order, fn facet ->
      %{
        facet: facet,
        limit: limit(facet),
        single: single?(facet),
        entries:
          Enum.map(entries(facet), fn {slug, name} -> {slug, name, subgenre_genre(slug)} end)
      }
    end)
  end

  @doc """
  Corrects the commonest era mistake: "atualidade" (2020 onward) on a title
  released before 2019, which almost always means "the present day of when it
  was made". It becomes the decade of the release year instead.
  """
  @spec fix_eras([String.t()], integer() | nil) :: [String.t()]
  def fix_eras(eras, year) when is_integer(year) and year > 1_800 and year < 2_019 do
    eras
    |> Enum.flat_map(fn
      "atualidade" -> List.wrap(decade(year))
      era -> [era]
    end)
    |> Enum.uniq()
  end

  def fix_eras(eras, _year), do: eras

  defp decade(year) when year >= 1_900 and year < 1_930, do: "anos-1900-1920"
  defp decade(year) when year >= 1_930, do: "anos-#{div(year, 10) * 10}"
  defp decade(_year), do: nil

  @doc """
  Keeps the slugs of a facet that belong to the vocabulary, deduplicated and
  capped at the facet's limit, in the order given.
  """
  @spec sanitize(facet(), term()) :: [String.t()]
  def sanitize(facet, values) when is_list(values) do
    names = Map.fetch!(@names, facet)

    values
    |> Enum.filter(&(is_binary(&1) and Map.has_key?(names, &1)))
    |> Enum.uniq()
    |> Enum.take(limit(facet))
  end

  def sanitize(facet, value) when is_binary(value), do: sanitize(facet, [value])
  def sanitize(_facet, _values), do: []
end
