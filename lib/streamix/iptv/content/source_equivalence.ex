defmodule Streamix.Iptv.Content.SourceEquivalence do
  @moduledoc """
  Persists high-confidence equivalence between provider-scoped catalog items.

  Automatic links are intentionally conservative:

    * shared external IDs (TMDB, IMDb, AniList or Tomato): confidence 100
    * exact normalized title plus the same known release year: confidence 92

  Live channels are never auto-linked by name or EPG ID because those values
  are routinely reused by unrelated provider feeds. They can still be linked
  explicitly through `link_verified/2`.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, ContentSourceGroup, Movie, Series}
  alias Streamix.Iptv.Content.VariantCards
  alias Streamix.Repo

  @type identity :: %{
          content_type: String.t(),
          canonical_key: String.t(),
          canonical_title: String.t() | nil,
          canonical_year: integer() | nil,
          method: String.t(),
          confidence: 0..100
        }

  @doc "Returns the strongest safe identity available for a content row."
  @spec identity(struct()) :: identity() | nil
  def identity(%Movie{} = movie) do
    external_identity("movie", "tmdb", movie.tmdb_id, movie) ||
      external_identity("movie", "imdb", movie.imdb_id, movie) ||
      title_year_identity("movie", movie)
  end

  def identity(%Series{} = series) do
    external_identity("series", "tmdb", series.tmdb_id, series) ||
      external_identity("series", "anilist", series.anilist_id, series) ||
      external_identity("series", "tomato", series.tomato_id, series) ||
      title_year_identity("series", series)
  end

  def identity(_content), do: nil

  @doc "Reconciles source groups for rows returned by a sync upsert."
  @spec reconcile_content_ids(module(), [integer()]) :: {:ok, non_neg_integer()}
  def reconcile_content_ids(_schema, []), do: {:ok, 0}

  def reconcile_content_ids(schema, content_ids)
      when schema in [Movie, Series] and is_list(content_ids) do
    contents =
      schema
      |> where([content], content.id in ^content_ids)
      |> Repo.all()

    reconcile_contents(contents)
  end

  def reconcile_content_ids(_schema, _content_ids), do: {:ok, 0}

  @doc "Reconciles already-loaded Movie/Series rows in one bulk update."
  @spec reconcile_contents([struct()]) :: {:ok, non_neg_integer()}
  def reconcile_contents(contents) when is_list(contents) do
    links =
      contents
      |> Enum.map(fn content -> {content, identity(content)} end)
      |> Enum.reject(fn {_content, identity} -> is_nil(identity) end)

    case links do
      [] ->
        {:ok, 0}

      links ->
        now = DateTime.utc_now(:second)
        ensure_groups(links, now)
        group_ids = fetch_group_ids(links)
        bulk_link_catalog_items(links, group_ids, now)
    end
  end

  @doc "Returns every catalog item currently linked to the same source group."
  @spec catalog_item_ids(integer()) :: [integer()]
  def catalog_item_ids(catalog_item_id) when is_integer(catalog_item_id) do
    case Repo.get(CatalogItem, catalog_item_id) do
      %CatalogItem{source_group_id: nil} ->
        []

      %CatalogItem{source_group_id: group_id} ->
        CatalogItem
        |> where(source_group_id: ^group_id)
        |> select([item], item.id)
        |> Repo.all()

      nil ->
        []
    end
  end

  def catalog_item_ids(_catalog_item_id), do: []

  @doc "Explicitly links catalog items after human/provider-specific verification."
  @spec link_verified([integer()], keyword()) ::
          {:ok, ContentSourceGroup.t()} | {:error, term()}
  def link_verified(catalog_item_ids, opts \\ []) when is_list(catalog_item_ids) do
    ids = Enum.uniq(catalog_item_ids)

    Repo.transact(fn ->
      items =
        CatalogItem
        |> where([item], item.id in ^ids)
        |> lock("FOR UPDATE")
        |> Repo.all()

      case validate_manual_items(ids, items) do
        :ok -> {:ok, create_manual_link!(ids, items, opts)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp create_manual_link!(ids, items, opts) do
    now = DateTime.utc_now(:second)
    content_type = items |> hd() |> Map.fetch!(:content_type)

    group =
      %ContentSourceGroup{}
      |> ContentSourceGroup.changeset(%{
        content_type: content_type,
        canonical_key: "manual:#{Ecto.UUID.generate()}",
        canonical_title: Keyword.get(opts, :canonical_title),
        canonical_year: Keyword.get(opts, :canonical_year)
      })
      |> Repo.insert!()

    CatalogItem
    |> where([item], item.id in ^ids)
    |> Repo.update_all(
      set: [
        source_group_id: group.id,
        source_match_method: "manual",
        source_match_confidence: 100,
        source_verified_at: now,
        updated_at: now
      ]
    )

    group
  end

  defp external_identity(content_type, namespace, value, content) do
    case normalized_external_id(value) do
      nil ->
        nil

      external_id ->
        %{
          content_type: content_type,
          canonical_key: "#{namespace}:#{external_id}",
          canonical_title: canonical_title(content),
          canonical_year: VariantCards.release_year(content),
          method: namespace,
          confidence: 100
        }
    end
  end

  defp title_year_identity(content_type, content) do
    title = Map.get(content, :title) || Map.get(content, :name)
    normalized_title = VariantCards.normalize_title(title)
    year = VariantCards.release_year(content)

    if VariantCards.reliable_title?(title) and normalized_title != "" and
         is_integer(year) and year in 1888..2200 do
      digest =
        :crypto.hash(:sha256, normalized_title <> "\0" <> Integer.to_string(year))
        |> Base.encode16(case: :lower)

      %{
        content_type: content_type,
        canonical_key: "title_year:#{digest}",
        canonical_title: VariantCards.strip_variant_terms(title),
        canonical_year: year,
        method: "title_year",
        confidence: 92
      }
    end
  end

  defp ensure_groups(links, now) do
    entries =
      links
      |> Enum.map(fn {_content, identity} ->
        %{
          content_type: identity.content_type,
          canonical_key: identity.canonical_key,
          canonical_title: identity.canonical_title,
          canonical_year: identity.canonical_year,
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.uniq_by(&{&1.content_type, &1.canonical_key})

    Repo.insert_all(ContentSourceGroup, entries,
      on_conflict: :nothing,
      conflict_target: [:content_type, :canonical_key]
    )
  end

  defp fetch_group_ids(links) do
    identities = Enum.map(links, &elem(&1, 1))
    content_types = Enum.map(identities, & &1.content_type) |> Enum.uniq()
    canonical_keys = Enum.map(identities, & &1.canonical_key) |> Enum.uniq()

    ContentSourceGroup
    |> where([group], group.content_type in ^content_types)
    |> where([group], group.canonical_key in ^canonical_keys)
    |> select([group], {{group.content_type, group.canonical_key}, group.id})
    |> Repo.all()
    |> Map.new()
  end

  defp bulk_link_catalog_items(links, group_ids, now) do
    rows =
      Enum.map(links, fn {content, identity} ->
        group_id = Map.fetch!(group_ids, {identity.content_type, identity.canonical_key})
        {content.catalog_item_id, group_id, identity.method, identity.confidence}
      end)

    {catalog_item_ids, group_ids, methods, confidences} = unzip_links(rows)

    result =
      Repo.query!(
        """
        UPDATE catalog_items AS item
        SET source_group_id = link.group_id,
            source_match_method = link.method,
            source_match_confidence = link.confidence,
            updated_at = $5
        FROM unnest($1::bigint[], $2::bigint[], $3::text[], $4::smallint[])
             AS link(catalog_item_id, group_id, method, confidence)
        WHERE item.id = link.catalog_item_id
          AND item.source_verified_at IS NULL
          AND (
            item.source_match_confidence IS NULL
            OR item.source_match_confidence < link.confidence
          )
        """,
        [catalog_item_ids, group_ids, methods, confidences, now]
      )

    {:ok, result.num_rows}
  end

  defp unzip_links(rows) do
    Enum.reduce(rows, {[], [], [], []}, fn {catalog_item_id, group_id, method, confidence},
                                           {catalog_ids, group_ids, methods, confidences} ->
      {
        [catalog_item_id | catalog_ids],
        [group_id | group_ids],
        [method | methods],
        [confidence | confidences]
      }
    end)
  end

  defp validate_manual_items(ids, items) do
    cond do
      length(ids) < 2 ->
        {:error, :at_least_two_sources_required}

      length(items) != length(ids) ->
        {:error, :catalog_item_not_found}

      items |> Enum.map(& &1.content_type) |> Enum.uniq() |> length() != 1 ->
        {:error, :content_type_mismatch}

      true ->
        :ok
    end
  end

  defp normalized_external_id(value) when is_integer(value) and value > 0,
    do: Integer.to_string(value)

  defp normalized_external_id(value) when is_binary(value) do
    case String.trim(value) do
      value when value in ["", "0"] -> nil
      value -> String.downcase(value)
    end
  end

  defp normalized_external_id(_), do: nil

  defp canonical_title(content) do
    content
    |> then(&(Map.get(&1, :title) || Map.get(&1, :name)))
    |> VariantCards.strip_variant_terms()
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
