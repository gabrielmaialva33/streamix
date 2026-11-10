defmodule Streamix.Iptv.Tags do
  @moduledoc """
  Fine-grained tags per title: subgenres, mood, pace, era, setting, audience,
  themes and source material, from the closed `Streamix.Iptv.Tags.Vocabulary`.

  A title is its `variant_key`, so every provider copy shares one row and is
  classified once. Titles become pending when they have no row, or one made
  against an older vocabulary version. Only titles with something to read
  (a synopsis or TMDB keywords) are ever pending: a bare release name would
  only invite a guess. A TMDB-matched title is pending only once its TMDB
  keywords and credits were fetched.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Content.VodAvailability
  alias Streamix.Iptv.{Movie, Provider, SearchDocuments, Series, TitleTags}
  alias Streamix.Iptv.Tags.Vocabulary
  alias Streamix.Repo

  @type kind :: :movies | :series
  @type facets :: %{optional(Vocabulary.facet()) => [String.t()] | String.t() | nil}

  @doc "The stored kind of a search kind: anime is stored as series."
  @spec kind_of(:movies | :series | :animes) :: String.t()
  def kind_of(:movies), do: "movies"
  def kind_of(kind) when kind in [:series, :animes], do: "series"

  @doc """
  Search documents (see `Streamix.Iptv.SearchDocuments`) for up to `limit`
  pending titles of a kind, one representative copy per title: the oldest
  live, non-adult copy on an active provider.
  """
  @spec pending_documents(kind(), pos_integer()) :: [map()]
  def pending_documents(kind, limit) when kind in [:movies, :series] and limit > 0 do
    ids = pending_ids(kind, limit)
    SearchDocuments.for_ids(kind, ids)
  end

  @doc "How many titles of a kind are pending."
  @spec pending_count(kind()) :: non_neg_integer()
  def pending_count(kind) when kind in [:movies, :series] do
    kind
    |> pending_query()
    |> exclude(:order_by)
    |> exclude(:distinct)
    |> select([content: c], count(c.variant_key, :distinct))
    |> Repo.one()
  end

  defp pending_ids(kind, limit) do
    kind
    |> pending_query()
    |> limit(^limit)
    |> select([content: c], c.id)
    |> Repo.all()
  end

  defp pending_query(kind) do
    stored = kind_of(kind)
    version = Vocabulary.version()

    from(c in schema_for(kind),
      as: :content,
      join: p in Provider,
      on: p.id == c.provider_id and p.is_active == true,
      left_join: t in TitleTags,
      on: t.kind == ^stored and t.variant_key == c.variant_key,
      where: is_nil(t.id) or t.vocabulary_version < ^version,
      where: not is_nil(c.title) and not is_nil(c.variant_key),
      distinct: c.variant_key,
      order_by: [asc: c.variant_key, asc: c.id]
    )
    |> readable()
    |> not_adult()
    |> VodAvailability.exclude_dead()
  end

  # Something to read: a synopsis or TMDB keywords. A TMDB-matched title
  # also waits for its keywords and credits: classified without them it
  # would keep the poorer tags until the next vocabulary version.
  defp readable(query) do
    where(
      query,
      [content: c],
      ((not is_nil(c.plot) and c.plot != "") or
         fragment("coalesce(cardinality(?), 0) > 0", c.tmdb_keyword_ids)) and
        (is_nil(c.tmdb_id) or c.tmdb_id == "" or not is_nil(c.tmdb_keyword_ids))
    )
  end

  defp not_adult(query) do
    adult =
      from(ic in "item_categories",
        join: k in "categories",
        on: k.id == ic.category_id,
        where: ic.catalog_item_id == parent_as(:content).catalog_item_id and k.is_adult,
        select: 1
      )

    where(query, not exists(adult))
  end

  defp schema_for(:movies), do: Movie
  defp schema_for(:series), do: Series

  @doc """
  Stores a title's classification, replacing any earlier one. Slugs outside
  the vocabulary are dropped and lists capped; the row records the model and
  the vocabulary version it was made against. Pass the release `:year` so
  `Streamix.Iptv.Tags.Vocabulary.fix_eras/2` can correct the era.
  """
  @spec put(String.t(), String.t(), facets(), String.t(), keyword()) ::
          {:ok, TitleTags.t()} | {:error, Ecto.Changeset.t()}
  def put(kind, variant_key, facets, model, opts \\ []) when is_map(facets) do
    attrs =
      Vocabulary.facets()
      |> Map.new(fn facet -> {facet, sanitize(facet, Map.get(facets, facet))} end)
      |> Map.update!(:eras, &Vocabulary.fix_eras(&1, Keyword.get(opts, :year)))
      |> Map.merge(%{
        kind: kind,
        variant_key: variant_key,
        model: model,
        vocabulary_version: Vocabulary.version()
      })

    %TitleTags{}
    |> TitleTags.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :kind, :variant_key, :inserted_at]},
      conflict_target: [:kind, :variant_key],
      returning: true
    )
  end

  defp sanitize(facet, value) do
    slugs = Vocabulary.sanitize(facet, value)
    if Vocabulary.single?(facet), do: List.first(slugs), else: slugs
  end

  @doc "Stored tags by variant key; titles without a row are left out."
  @spec for_variants(String.t(), [String.t() | nil]) :: %{String.t() => TitleTags.t()}
  def for_variants(kind, keys) do
    case keys |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      keys ->
        Repo.all(from(t in TitleTags, where: t.kind == ^kind and t.variant_key in ^keys))
        |> Map.new(&{&1.variant_key, &1})
    end
  end

  @doc "The facets of a stored row as a plain map of slugs, or nil."
  @spec to_map(TitleTags.t() | nil) :: map() | nil
  def to_map(nil), do: nil
  def to_map(%TitleTags{} = tags), do: Map.take(tags, Vocabulary.facets())

  @doc "The facets of a stored row as pt-BR labels (singular facets as one-item lists), or nil."
  @spec labels(TitleTags.t() | nil) :: %{Vocabulary.facet() => [String.t()]} | nil
  def labels(nil), do: nil

  def labels(%TitleTags{} = tags) do
    Map.new(Vocabulary.facets(), fn facet ->
      {facet,
       tags
       |> Map.fetch!(facet)
       |> List.wrap()
       |> Enum.flat_map(&List.wrap(Vocabulary.name(facet, &1)))}
    end)
  end

  @doc "Titles classified so far, per stored kind."
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    Repo.all(from(t in TitleTags, group_by: t.kind, select: {t.kind, count(t.id)}))
    |> Map.new()
  end
end
