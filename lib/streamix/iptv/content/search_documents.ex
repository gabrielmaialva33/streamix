defmodule Streamix.Iptv.SearchDocuments do
  alias Streamix.Iptv.Content.VodAvailability

  @moduledoc """
  Read projection used by search indexers.

  The projection keeps IPTV persistence and schema knowledge inside this
  context while exposing only the fields needed to build search documents.
  """

  import Ecto.Query, warn: false

  alias Streamix.Helpers
  alias Streamix.Iptv.Content.GindexSeries
  alias Streamix.Iptv.{Movie, Provider, Series, TmdbMetadata}
  alias Streamix.Repo

  @type kind :: :movies | :series | :animes

  @page_size 2_000

  @spec list(kind(), integer() | nil, keyword()) :: [map()]
  def list(kind, provider_id \\ nil, opts \\ [])
      when kind in [:movies, :series, :animes] and
             (is_nil(provider_id) or is_integer(provider_id)) and
             is_list(opts) do
    after_id = Keyword.get(opts, :after_id, 0)

    unless is_integer(after_id) and after_id >= 0 do
      raise ArgumentError, "expected :after_id to be a non-negative integer"
    end

    page_size = Keyword.get(opts, :page_size, @page_size)

    # Keyset pages keep each query short. Loading the whole catalog in one
    # query held a connection past its 15 s checkout and dropped it, failing
    # the nightly indexing run.
    Stream.unfold(after_id, fn
      nil ->
        nil

      cursor ->
        page =
          kind
          |> schema_for()
          |> base_query(cursor)
          |> VodAvailability.exclude_dead()
          |> scope_to_kind(kind)
          |> maybe_filter_provider(provider_id)
          |> limit(^page_size)
          |> Repo.all()

        next = if length(page) == page_size, do: List.last(page).id, else: nil
        if page == [], do: nil, else: {with_keyword_names(page), next}
    end)
    |> Stream.flat_map(& &1)
    |> Enum.map(fn {content, keywords} -> to_document(content, keywords) end)
  end

  defp schema_for(:movies), do: Movie
  defp schema_for(:series), do: Series
  defp schema_for(:animes), do: Series

  # Anime and series share a table but are separate collections, exactly as
  # the catalog presents them. Without the exclusion anime would be indexed
  # twice and turn up in series searches.
  defp scope_to_kind(query, :animes), do: GindexSeries.only_animes(query)
  defp scope_to_kind(query, :series), do: GindexSeries.exclude_animes(query)
  defp scope_to_kind(query, :movies), do: query

  defp base_query(schema, after_id) do
    from(content in schema,
      as: :content,
      join: provider in Provider,
      as: :provider,
      on: provider.id == content.provider_id,
      where: not is_nil(content.title) and content.id > ^after_id,
      where: provider.is_active == true,
      order_by: [asc: content.id],
      select_merge: %{variant_key: content.variant_key},
      preload: [:genres, credits: :person]
    )
  end

  defp maybe_filter_provider(query, nil), do: query

  defp maybe_filter_provider(query, provider_id) do
    from([content: content] in query, where: content.provider_id == ^provider_id)
  end

  # One lookup per page for every keyword the page's titles carry.
  defp with_keyword_names(page) do
    names =
      page
      |> Enum.flat_map(&(&1.tmdb_keyword_ids || []))
      |> Enum.uniq()
      |> TmdbMetadata.keyword_names()

    Enum.map(page, fn content ->
      {content, Enum.flat_map(content.tmdb_keyword_ids || [], &List.wrap(names[&1]))}
    end)
  end

  defp to_document(content, keywords) do
    %{
      id: content.id,
      title: content.title,
      plot: content.plot,
      tagline: content.tagline,
      year: content.year,
      genres: Helpers.genre_names(content.genres),
      keywords: keywords,
      directors: people(content.credits, "director"),
      writers: people(content.credits, "writer"),
      cast: people(content.credits, "cast"),
      rating: content.rating,
      provider_id: content.provider_id,
      variant_key: content.variant_key
    }
  end

  # Names are stored lowercased; title-case them back for the embedding text.
  defp people(credits, role) do
    credits
    |> Enum.filter(&(&1.role == role))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&display_name(&1.person.name))
  end

  defp display_name(name) do
    name |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)
  end
end
