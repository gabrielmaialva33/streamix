defmodule Streamix.Iptv.Genres do
  @moduledoc """
  Keeps genres canonical: the rows of `Streamix.Iptv.Genres.Vocabulary`, never
  a raw provider string.

  A title's genres are derived, in order of strength:

    1. usable TMDB genre ids, when fetched;
    2. its provider genre string, mapped by `Streamix.Iptv.Genres.Normalizer`
       (series carry one; Xtream movie lists do not);
    3. otherwise its provider category names ("▶️ Terror & Suspense");
    4. none at all when any of its categories is adult, the rule
       `Streamix.Iptv.AdultFilter` applies to listings.

  Sync calls `reconcile/4` for the whole provider, so a changed string, a
  changed category or a title turning adult replaces the old genres instead
  of piling up. `canonicalize/0` converts a catalog that still holds the raw
  names sync used to create; run it with all genre writers drained, including
  sync, TMDB backfills and request-triggered enrichment, since it rewrites links.
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
    {:ok, result} =
      genre_transaction(kind, fn -> reconcile_locked(kind, provider_id, string_genres, ids) end)

    result
  end

  defp reconcile_locked(kind, provider_id, string_genres, ids) do
    config = %{content: content, type: type} = Map.fetch!(@kinds, kind)
    {item_ids, genre_ids} = Enum.unzip(string_genres)
    {category_ids, category_genre_ids} = category_genres(type, provider_id, ids)

    replace_links(
      config,
      """
      SELECT c.id, c.catalog_item_id,
             coalesce(c.tmdb_genre_ids && $6::integer[], false) AS owned,
             #{adult_sql()} AS adult
      FROM #{content} c WHERE c.provider_id = $3
      """,
      """
      SELECT s.item_id, s.genre_id
      FROM unnest($1::bigint[], $2::bigint[]) AS s(item_id, genre_id)
      JOIN items i ON i.id = s.item_id WHERE NOT i.owned AND NOT i.adult
      UNION
      SELECT i.id, m.genre_id FROM items i
      JOIN item_categories ic ON ic.catalog_item_id = i.catalog_item_id
      JOIN unnest($4::bigint[], $5::bigint[]) AS m(category_id, genre_id)
        ON m.category_id = ic.category_id
      WHERE NOT i.owned AND NOT i.adult
        AND NOT (i.id = ANY($1::bigint[]))
      """,
      [item_ids, genre_ids, provider_id, category_ids, category_genre_ids, tmdb_ids(kind)]
    )
  end

  @doc """
  Stores a fetched TMDB genre list on every matching copy and replaces its links
  when the mapping is usable. Empty mappings preserve fallback links; adult
  copies always lose their links. The whole application is one transaction.
  """
  @spec apply_tmdb(:movies | :series, String.t() | integer(), [integer()]) ::
          {:ok, map()} | {:error, term()}
  def apply_tmdb(kind, tmdb_id, genre_ids)
      when (is_binary(tmdb_id) and tmdb_id != "") or (is_integer(tmdb_id) and tmdb_id > 0) do
    unless is_list(genre_ids) and Enum.all?(genre_ids, &is_integer/1) do
      raise ArgumentError, "TMDB genre ids must be a list of integers"
    end

    genre_transaction(kind, fn -> apply_tmdb_locked(kind, to_string(tmdb_id), genre_ids) end)
  end

  defp apply_tmdb_locked(kind, tmdb_id, genre_ids) do
    config = %{content: content} = Map.fetch!(@kinds, kind)
    ids = canonical_ids()

    desired_ids =
      kind |> tmdb_type() |> Vocabulary.from_tmdb(genre_ids) |> Enum.map(&Map.fetch!(ids, &1))

    # One statement gives the stored ids and link replacement the same target
    # snapshot, including when catalog rows are being inserted concurrently.
    replace_links(
      config,
      """
      SELECT c.id, cardinality($3::bigint[]) = 0 AS owned, #{adult_sql()} AS adult
      FROM #{content} c WHERE c.tmdb_id = $1 AND c.tmdb_id <> ''
      ORDER BY c.id FOR NO KEY UPDATE OF c
      """,
      """
      SELECT i.id AS item_id, g.genre_id
      FROM items i CROSS JOIN unnest($3::bigint[]) AS g(genre_id)
      WHERE NOT i.adult
      """,
      [tmdb_id, genre_ids, desired_ids],
      """
      UPDATE #{content} c SET tmdb_genre_ids = $2::integer[]
      FROM items i WHERE c.id = i.id AND c.tmdb_genre_ids IS DISTINCT FROM $2::integer[]
      RETURNING 1
      """
    )
  end

  @doc """
  Replaces only the submitted incremental source items' genres. TMDB-owned
  items are untouched, except that adult items always lose their links.
  """
  @spec put_string_genres(:movies | :series, [{integer(), String.t() | nil}]) :: map()
  def put_string_genres(_kind, []), do: %{removed: 0, added: 0}

  def put_string_genres(kind, items) do
    {:ok, result} = genre_transaction(kind, fn -> put_strings_locked(kind, items) end)
    result
  end

  defp put_strings_locked(kind, items) do
    config = %{content: content} = Map.fetch!(@kinds, kind)
    ids = canonical_ids()
    item_ids = items |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    {string_items, genre_ids} =
      items
      |> Enum.flat_map(fn {id, raw} ->
        for slug <- Normalizer.normalize(raw), do: {id, Map.fetch!(ids, slug)}
      end)
      |> Enum.unzip()

    replace_links(
      config,
      """
      SELECT c.id, coalesce(c.tmdb_genre_ids && $4::integer[], false) AS owned,
             #{adult_sql()} AS adult
      FROM #{content} c WHERE c.id = ANY($1::bigint[])
      """,
      """
      SELECT DISTINCT s.item_id, s.genre_id
      FROM unnest($2::bigint[], $3::bigint[]) AS s(item_id, genre_id)
      JOIN items i ON i.id = s.item_id WHERE NOT i.owned AND NOT i.adult
      """,
      [item_ids, string_items, genre_ids, tmdb_ids(kind)]
    )
  end

  # The gate spans ownership reads and writes, not just vocabulary initialization.
  # canonicalize remains an operational migration with all genre writers drained.
  defp genre_transaction(kind, fun) when kind in [:movies, :series] do
    Repo.transaction(
      fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtext($1))",
          ["streamix:genres:#{kind}"],
          timeout: :timer.minutes(5)
        )

        fun.()
      end,
      timeout: :timer.minutes(5)
    )
  end

  defp tmdb_type(:movies), do: :movie
  defp tmdb_type(:series), do: :tv
  defp tmdb_ids(kind), do: kind |> tmdb_type() |> Vocabulary.tmdb_ids()

  defp adult_sql do
    """
    EXISTS (SELECT 1 FROM item_categories ic JOIN categories k ON k.id = ic.category_id
            WHERE ic.catalog_item_id = c.catalog_item_id AND k.is_adult)
    """
  end

  defp replace_links(%{table: table, fk: fk}, items, desired, params, stored \\ nil) do
    %{rows: [[removed, added, updated]]} =
      Repo.query!(
        """
        WITH items AS (#{items}), desired AS (#{desired}),
        stored AS (#{stored || "SELECT 1 WHERE false"}),
        removed AS (
          DELETE FROM #{table} l USING items i
          WHERE l.#{fk} = i.id AND (NOT i.owned OR i.adult)
            AND NOT EXISTS (
              SELECT 1 FROM desired d WHERE d.item_id = l.#{fk} AND d.genre_id = l.genre_id
            )
          RETURNING 1
        ),
        added AS (
          INSERT INTO #{table} (#{fk}, genre_id)
          SELECT item_id, genre_id FROM desired ORDER BY 1, 2
          ON CONFLICT DO NOTHING RETURNING 1
        )
        SELECT (SELECT count(*) FROM removed), (SELECT count(*) FROM added),
               (SELECT count(*) FROM stored)
        """,
        params,
        timeout: :timer.minutes(5)
      )

    result = %{removed: removed, added: added}
    if stored, do: Map.put(result, :updated, updated), else: result
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
