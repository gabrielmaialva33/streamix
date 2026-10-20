defmodule Streamix.Iptv.Genres do
  @moduledoc """
  Keeps genres canonical: the rows of `Streamix.Iptv.Genres.Vocabulary`, never
  a raw provider string.

  A title's genres are derived, in order of strength:

    1. its provider genre string, mapped by `Streamix.Iptv.Genres.Normalizer`
       (series carry one; Xtream movie lists do not);
    2. otherwise its provider category names ("▶️ Terror & Suspense");
    3. none at all when any of its categories is adult, the rule
       `Streamix.Iptv.AdultFilter` applies to listings.

  Sync calls `reconcile/4` for the whole provider, so a changed string, a
  changed category or a title turning adult replaces the old genres instead
  of piling up. `canonicalize/0` converts a catalog that still holds the raw
  names sync used to create; run it with the `sync` queue paused, since it
  rewrites links a running sync would also write.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Genre
  alias Streamix.Iptv.Genres.{Normalizer, Vocabulary}
  alias Streamix.Repo

  @kinds %{
    movies: %{table: "movie_genres", fk: "movie_id", content: "movies", type: "vod"},
    series: %{table: "series_genres", fk: "series_id", content: "series", type: "series"}
  }

  @lock_key "streamix:genres:canonical"

  @doc """
  Canonical genre ids by slug, creating the vocabulary rows the first time.
  """
  @spec canonical_ids() :: %{String.t() => integer()}
  def canonical_ids do
    ids = slug_ids()

    if map_size(ids) == length(Vocabulary.all()) do
      ids
    else
      {:ok, ids} =
        Repo.transaction(fn ->
          lock()
          ensure_canonical_rows()
        end)

      ids
    end
  end

  @doc """
  Replaces the genres of every `kind` title of a provider with the derived set.

  `string_genres` holds `{item_id, genre_id}` pairs from the provider genre
  strings of this sync; a title without any falls back to its categories.
  Returns how many links were removed and added.
  """
  @spec reconcile(:movies | :series, integer(), [{integer(), integer()}], map()) ::
          %{removed: non_neg_integer(), added: non_neg_integer()}
  def reconcile(kind, provider_id, string_genres, ids \\ canonical_ids()) do
    %{table: table, fk: fk, content: content, type: type} = Map.fetch!(@kinds, kind)
    {item_ids, genre_ids} = Enum.unzip(string_genres)
    {category_ids, category_genre_ids} = category_genres(type, provider_id, ids)

    %{rows: [[removed, added]]} =
      Repo.query!(
        """
        WITH strings AS (
          SELECT * FROM unnest($1::bigint[], $2::bigint[]) AS s(item_id, genre_id)
        ),
        items AS (
          SELECT c.id, c.catalog_item_id
          FROM #{content} c
          WHERE c.provider_id = $3
            AND NOT EXISTS (
              SELECT 1 FROM item_categories ic
              JOIN categories k ON k.id = ic.category_id
              WHERE ic.catalog_item_id = c.catalog_item_id AND k.is_adult
            )
        ),
        desired AS (
          SELECT s.item_id, s.genre_id FROM strings s JOIN items i ON i.id = s.item_id
          UNION
          SELECT i.id, m.genre_id
          FROM items i
          JOIN item_categories ic ON ic.catalog_item_id = i.catalog_item_id
          JOIN unnest($4::bigint[], $5::bigint[]) AS m(category_id, genre_id)
            ON m.category_id = ic.category_id
          WHERE NOT EXISTS (SELECT 1 FROM strings s WHERE s.item_id = i.id)
        ),
        removed AS (
          DELETE FROM #{table} l
          USING #{content} c
          WHERE l.#{fk} = c.id AND c.provider_id = $3
            AND NOT EXISTS (
              SELECT 1 FROM desired d WHERE d.item_id = l.#{fk} AND d.genre_id = l.genre_id
            )
          RETURNING 1
        ),
        added AS (
          INSERT INTO #{table} (#{fk}, genre_id)
          SELECT item_id, genre_id FROM desired ORDER BY 1, 2
          ON CONFLICT DO NOTHING
          RETURNING 1
        )
        SELECT (SELECT count(*) FROM removed), (SELECT count(*) FROM added)
        """,
        [item_ids, genre_ids, provider_id, category_ids, category_genre_ids],
        timeout: :timer.minutes(5)
      )

    %{removed: removed, added: added}
  end

  @doc """
  Converts the catalog to canonical genres, in one transaction.

  Every vocabulary row takes over the raw row that already meant it (keeping
  its id and links); every other raw row has its links moved to the genres
  its name normalizes to and is deleted. Titles still without a genre get
  their categories' genres, and adult titles lose theirs. Running it again
  changes nothing.
  """
  @spec canonicalize() :: {:ok, map()} | {:error, term()}
  def canonicalize do
    Repo.transaction(
      fn ->
        lock()
        ids = ensure_canonical_rows()
        {moved, deleted} = remap_raw_rows(ids)

        Map.merge(
          %{genres: map_size(ids), moved_links: moved, deleted_raw_genres: deleted},
          Map.new(Map.keys(@kinds), &{&1, fill_and_veto(&1, ids)})
        )
      end,
      timeout: :timer.minutes(15)
    )
  end

  # Category genres for titles without any genre, then no genre on adult titles.
  defp fill_and_veto(kind, ids) do
    %{table: table, fk: fk, content: content, type: type} = Map.fetch!(@kinds, kind)
    {category_ids, genre_ids} = category_genres(type, nil, ids)

    %{num_rows: filled} =
      Repo.query!(
        """
        INSERT INTO #{table} (#{fk}, genre_id)
        SELECT DISTINCT c.id, m.genre_id
        FROM #{content} c
        JOIN item_categories ic ON ic.catalog_item_id = c.catalog_item_id
        JOIN unnest($1::bigint[], $2::bigint[]) AS m(category_id, genre_id)
          ON m.category_id = ic.category_id
        WHERE NOT EXISTS (SELECT 1 FROM #{table} g WHERE g.#{fk} = c.id)
        ON CONFLICT DO NOTHING
        """,
        [category_ids, genre_ids],
        timeout: :timer.minutes(10)
      )

    %{num_rows: vetoed} =
      Repo.query!(
        """
        DELETE FROM #{table} l
        USING #{content} c
        WHERE l.#{fk} = c.id
          AND EXISTS (
            SELECT 1 FROM item_categories ic
            JOIN categories k ON k.id = ic.category_id
            WHERE ic.catalog_item_id = c.catalog_item_id AND k.is_adult
          )
        """,
        [],
        timeout: :timer.minutes(10)
      )

    %{filled_from_categories: filled, removed_from_adult: vetoed}
  end

  # {category_ids, genre_ids} pairs for the non-adult categories of a type
  # (one provider, or all), from what their names normalize to.
  defp category_genres(type, provider_id, ids) do
    "categories"
    |> where([c], c.type == ^type and not c.is_adult)
    |> then(fn query ->
      if provider_id, do: where(query, [c], c.provider_id == ^provider_id), else: query
    end)
    |> select([c], {c.id, c.name})
    |> Repo.all()
    |> Enum.flat_map(fn {category_id, name} ->
      for slug <- Normalizer.normalize(name), id = ids[slug], do: {category_id, id}
    end)
    |> Enum.unzip()
  end

  defp slug_ids do
    Genre
    |> where([g], not is_nil(g.slug))
    |> select([g], {g.slug, g.id})
    |> Repo.all()
    |> Map.new()
  end

  # Serializes concurrent callers creating the vocabulary rows.
  defp lock, do: Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@lock_key])

  defp ensure_canonical_rows do
    rows = Repo.all(from g in Genre, select: %{id: g.id, name: g.name, slug: g.slug})
    usage = link_counts()
    now = DateTime.utc_now(:second)

    Map.new(Vocabulary.all(), fn %{slug: slug, name: name, position: position} ->
      id =
        case Enum.find(rows, &(&1.slug == slug)) || raw_row_meaning(rows, usage, slug, name) do
          %{id: id} ->
            # `name` is citext, so compare it as text: "drama" must become "Drama".
            Genre
            |> where([g], g.id == ^id)
            |> where(
              [g],
              fragment("?::text", g.name) != ^name or is_nil(g.slug) or g.slug != ^slug or
                is_nil(g.position) or g.position != ^position
            )
            |> Repo.update_all(set: [name: name, slug: slug, position: position, updated_at: now])

            id

          nil ->
            Repo.insert!(%Genre{name: name, slug: slug, position: position}).id
        end

      {slug, id}
    end)
  end

  # The raw row to promote: the one already named like the label, otherwise
  # the most linked of those whose name means exactly this genre.
  defp raw_row_meaning(rows, usage, slug, name) do
    candidates = Enum.filter(rows, &(is_nil(&1.slug) and Normalizer.normalize(&1.name) == [slug]))

    Enum.find(candidates, &(String.downcase(&1.name) == String.downcase(name))) ||
      Enum.max_by(candidates, &Map.get(usage, &1.id, 0), fn -> nil end)
  end

  defp link_counts do
    for %{table: table} <- Map.values(@kinds), reduce: %{} do
      acc ->
        %{rows: rows} = Repo.query!("SELECT genre_id, count(*) FROM #{table} GROUP BY 1")
        Enum.reduce(rows, acc, fn [id, n], acc -> Map.update(acc, id, n, &(&1 + n)) end)
    end
  end

  defp remap_raw_rows(ids) do
    canonical = Map.values(ids)
    raw = Repo.all(from g in Genre, where: g.id not in ^canonical, select: {g.id, g.name})

    {old_ids, new_ids} =
      raw
      |> Enum.flat_map(fn {id, name} ->
        for slug <- Normalizer.normalize(name), do: {id, Map.fetch!(ids, slug)}
      end)
      |> Enum.unzip()

    moved =
      for %{table: table, fk: fk} <- Map.values(@kinds), reduce: 0 do
        acc ->
          %{num_rows: n} =
            Repo.query!(
              """
              INSERT INTO #{table} (#{fk}, genre_id)
              SELECT l.#{fk}, m.new_id
              FROM #{table} l
              JOIN unnest($1::bigint[], $2::bigint[]) AS m(old_id, new_id) ON m.old_id = l.genre_id
              ON CONFLICT DO NOTHING
              """,
              [old_ids, new_ids],
              timeout: :timer.minutes(10)
            )

          acc + n
      end

    # The old links go with their rows (on_delete: :delete_all).
    {deleted, _} = Repo.delete_all(from g in Genre, where: g.id not in ^canonical)
    {moved, deleted}
  end
end
