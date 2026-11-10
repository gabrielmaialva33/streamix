defmodule Streamix.AI.TagClassifier do
  @moduledoc """
  Classifies titles into the closed tag vocabulary with a Gemini text model.

  Several titles go in one request, each with everything known about it
  (genres, TMDB keywords, credits, synopsis). The response schema lists every
  facet's slugs as a string enum, so the model can only pick from the
  vocabulary (`Streamix.Catalog.tag_vocabulary/0`); the catalog validates
  again before storing.

  Configured under `config :streamix, :tag_classifier`: `:model`
  (`TAG_CLASSIFIER_MODEL`) and `:thinking_level`. A sample of real catalog
  titles chose the defaults: gemini-3.5-flash-lite at low thinking caught
  subgenres ("natal", "quebra-cabeca", "criatura") the 3.1 lite model missed.
  """

  alias Streamix.AI.Gemini
  alias Streamix.Catalog

  @default_model "gemini-3.5-flash-lite"
  @default_thinking_level "low"
  @plot_limit 1_200
  @keyword_limit 25
  @people_limit 4

  @doc "The configured classification model."
  @spec model() :: String.t()
  def model, do: setting(:model, @default_model)

  defp thinking do
    case setting(:thinking_level, @default_thinking_level) do
      "none" -> nil
      level -> %{thinkingLevel: level}
    end
  end

  defp setting(key, default) do
    case :streamix |> Application.get_env(:tag_classifier, []) |> Keyword.get(key) do
      value when is_binary(value) and value != "" -> value
      _unset -> default
    end
  end

  @doc """
  Classifies search documents (each with a `:variant_key`). Returns the
  facets per variant key in input order, plus the token usage. A title the
  model left out of its answer is left out here too.

  Options: `:model` and `:max_retries` override the defaults.
  """
  @spec classify([map()], keyword()) ::
          {:ok, [{String.t(), map()}], map()} | {:error, term()}
  def classify(documents, opts \\ [])

  def classify([], _opts), do: {:ok, [], %{}}

  def classify(documents, opts) when is_list(documents) do
    vocabulary = Catalog.tag_vocabulary()
    refs = documents |> Enum.with_index(1) |> Map.new(fn {doc, ref} -> {ref, doc} end)
    prompt = refs |> Enum.sort() |> Enum.map_join("\n\n", fn {ref, doc} -> describe(ref, doc) end)

    with {:ok, answers, usage} <-
           Gemini.generate_json(system_prompt(vocabulary), prompt, response_schema(vocabulary),
             model: Keyword.get(opts, :model, model()),
             thinking: thinking(),
             max_retries: Keyword.get(opts, :max_retries, 4)
           ),
         true <- is_list(answers) || {:error, :invalid_answer} do
      {:ok, collect(answers, refs, vocabulary), usage}
    end
  end

  defp collect(answers, refs, vocabulary) do
    answers
    |> Enum.flat_map(fn
      %{"ref" => ref} = answer when is_map_key(refs, ref) ->
        [{ref, Map.fetch!(refs, ref).variant_key, facets(answer, vocabulary)}]

      _answer ->
        []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_ref, key, facets} -> {key, facets} end)
  end

  defp facets(answer, vocabulary) do
    Map.new(vocabulary, fn %{facet: facet} -> {facet, answer[Atom.to_string(facet)]} end)
  end

  # --- Prompt ---

  defp describe(ref, doc) do
    [
      "[#{ref}] #{doc.title}#{year(doc[:year])}",
      field("Gêneros", list(doc[:genres])),
      field("Palavras-chave TMDB", doc[:keywords] |> list() |> Enum.take(@keyword_limit)),
      field("Direção", doc[:directors] |> list() |> Enum.take(@people_limit)),
      field("Roteiro", doc[:writers] |> list() |> Enum.take(@people_limit)),
      field("Elenco", doc[:cast] |> list() |> Enum.take(@people_limit)),
      field("Tagline", text(doc[:tagline])),
      field("Sinopse", doc[:plot] |> text() |> truncate())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp year(year) when is_integer(year) and year > 0, do: " (#{year})"
  defp year(_year), do: ""

  defp field(_label, nil), do: nil
  defp field(_label, []), do: nil
  defp field(label, values) when is_list(values), do: "#{label}: #{Enum.join(values, ", ")}"
  defp field(label, value), do: "#{label}: #{value}"

  defp list(values) when is_list(values), do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  defp list(value) when is_binary(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp list(_value), do: []

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil

  defp truncate(nil), do: nil
  defp truncate(text) when byte_size(text) <= @plot_limit, do: text
  defp truncate(text), do: String.slice(text, 0, @plot_limit) <> "…"

  @doc false
  def system_prompt(vocabulary) do
    limits = Map.new(vocabulary, &{&1.facet, &1.limit})

    """
    You classify movies and TV series for a streaming catalog into a closed tag vocabulary.
    Each title arrives as "[ref] Title (year)" followed by what is known about it. Answer one
    object per title, with its ref, choosing slugs only from the lists below.

    Precision matters more than recall. Pick a tag only when the title clearly is that, using
    the synopsis, the TMDB keywords and what you reliably know about this exact title (match it
    by title, year and credits). When you do not recognize a title and its synopsis says little,
    answer fewer tags; an empty list is a valid answer. Never tag from the title's name alone.

    Facets:
    - subgenres (up to #{limits.subgenres}): the specific kinds of story it is, most defining
      first. A subgenre may refine a genre the title was not filed under: a Christmas romance
      is "natal" even when filed as drama.
    - moods (up to #{limits.moods}): how watching it feels.
    - pace (exactly one): how fast it moves.
    - eras (up to #{limits.eras}): WHEN THE STORY TAKES PLACE, never the release date. A story set
      in the present day of when it was made takes the decade of its release year: a 1999 film
      set in its own present is "anos-1990", a 2008 one "anos-2000". "atualidade" is ONLY for
      stories set in 2020 or later. "atemporal" is an invented world or an unplaceable time.
    - settings (up to #{limits.settings}): where most of it happens.
    - audience (exactly one): who it is for, by content intensity. "adulto-pesado" only for
      graphic violence, explicit sex or extreme content.
    - themes (up to #{limits.themes}): what it is about, most central first.
    - origins (up to #{limits.origins}): source material or format, only when known. TMDB
      keywords such as "based on novel or book", "based on memoir or autobiography", "based on
      true story", "based on comic", "sequel" and "remake" are strong evidence.

    #{vocabulary_listing(vocabulary)}
    """
  end

  defp vocabulary_listing(vocabulary) do
    Enum.map_join(vocabulary, "\n\n", fn %{facet: facet, entries: entries} ->
      lines =
        Enum.map_join(entries, "\n", fn
          {slug, name, nil} -> "- #{slug}: #{name}"
          {slug, name, genre} -> "- #{slug}: #{name} (#{genre})"
        end)

      "#{facet}:\n#{lines}"
    end)
  end

  @doc false
  def response_schema(vocabulary) do
    properties =
      Map.new(vocabulary, fn %{facet: facet, single: single, entries: entries} ->
        enum = %{type: "STRING", enum: Enum.map(entries, &elem(&1, 0))}
        {facet, if(single, do: enum, else: %{type: "ARRAY", items: enum})}
      end)

    names = ["ref" | Enum.map(vocabulary, &Atom.to_string(&1.facet))]

    %{
      type: "ARRAY",
      items: %{
        type: "OBJECT",
        properties: Map.put(properties, :ref, %{type: "INTEGER"}),
        required: names,
        propertyOrdering: names
      }
    }
  end
end
