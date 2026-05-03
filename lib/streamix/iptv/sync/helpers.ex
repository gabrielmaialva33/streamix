defmodule Streamix.Iptv.Sync.Helpers do
  @moduledoc """
  Shared helper functions for sync operations.
  Provides parsing utilities and category lookup building.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{CatalogItem, Category, Genre, Person}
  alias Streamix.Repo

  @batch_size 500

  def batch_size, do: @batch_size

  @doc """
  Builds a lookup map of external_id -> database id for categories.
  """
  def build_category_lookup(provider_id, type) do
    Category
    |> where(provider_id: ^provider_id, type: ^type)
    |> select([c], {c.external_id, c.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Parses a year value from various input types.
  """
  def parse_year(nil), do: nil
  def parse_year(year) when is_integer(year), do: year

  def parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {y, _} -> y
      :error -> nil
    end
  end

  @doc """
  Parses a decimal value from various input types.
  """
  def parse_decimal(nil), do: nil
  def parse_decimal(n) when is_number(n), do: Decimal.from_float(n / 1)

  def parse_decimal(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> Decimal.from_float(f)
      :error -> nil
    end
  end

  @doc """
  Parses an integer value from various input types.
  """
  def parse_int(nil), do: nil
  def parse_int(n) when is_integer(n), do: n

  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  @doc """
  Parses a date from ISO8601 string.
  """
  def parse_date(nil), do: nil

  def parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  @doc """
  Converts a value to string or returns nil.
  """
  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(val), do: to_string(val)

  # =============================================================================
  # Diff-based Category Association Rebuild (via item_categories)
  # =============================================================================

  @doc """
  Rebuilds category associations via `item_categories` using the content's
  `catalog_item_id`.

  Uses diff-based strategy: only inserts new associations and deletes obsolete
  ones, avoiding WAL bloat and momentary visibility gaps.

  ## Parameters

    * `catalog_item_ids` - List of catalog_item IDs being synced
    * `desired_assocs` - List of `%{catalog_item_id: X, category_id: Y}` maps

  """
  def rebuild_category_assocs_diff(catalog_item_ids, desired_assocs)
      when is_list(catalog_item_ids) do
    if Enum.empty?(catalog_item_ids) do
      :ok
    else
      do_rebuild_diff(catalog_item_ids, desired_assocs)
    end
  end

  defp do_rebuild_diff(catalog_item_ids, desired_assocs) do
    # 1. Fetch current associations from DB
    current_assocs =
      Repo.query!(
        "SELECT catalog_item_id, category_id FROM item_categories WHERE catalog_item_id = ANY($1)",
        [catalog_item_ids]
      )
      |> Map.get(:rows, [])
      |> MapSet.new(fn [ci_id, cat_id] -> {ci_id, cat_id} end)

    # 2. Build desired associations as MapSet
    desired_set =
      desired_assocs
      |> Enum.map(fn assoc ->
        {Map.get(assoc, :catalog_item_id), Map.get(assoc, :category_id)}
      end)
      |> Enum.reject(fn {e, c} -> is_nil(e) or is_nil(c) end)
      |> MapSet.new()

    # 3. Compute diff
    to_insert = MapSet.difference(desired_set, current_assocs)
    to_delete = MapSet.difference(current_assocs, desired_set)

    # 4. Bulk delete obsolete associations
    unless MapSet.size(to_delete) == 0 do
      delete_pairs = MapSet.to_list(to_delete)
      bulk_delete_item_category_assocs(delete_pairs)
    end

    # 5. Insert new associations
    unless MapSet.size(to_insert) == 0 do
      new_assocs =
        to_insert
        |> MapSet.to_list()
        |> Enum.map(fn {ci_id, cat_id} ->
          %{catalog_item_id: ci_id, category_id: cat_id}
        end)

      Repo.insert_all("item_categories", new_assocs)
    end

    :ok
  end

  defp bulk_delete_item_category_assocs(pairs) do
    values_clause =
      pairs
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_, i} -> "($#{i * 2 - 1}::bigint, $#{i * 2}::bigint)" end)

    params = Enum.flat_map(pairs, fn {ci_id, cat_id} -> [ci_id, cat_id] end)

    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE (catalog_item_id, category_id) IN (VALUES #{values_clause})
      """,
      params
    )
  end

  # =============================================================================
  # Generic Content Sync
  # =============================================================================

  @doc """
  Generic batched upsert for content types (live channels, movies, etc).

  Pre-creates catalog_items for NEW rows (catalog_item_id is NOT NULL),
  then upserts content with catalog_item_id set. Categories go through
  `item_categories` via catalog_item_id.

  ## Options
    * `:schema` - The Ecto schema module (e.g., LiveChannel, Movie)
    * `:attrs_fn` - Function (stream, provider_id, now) -> attrs map
    * `:category_fn` - Function (streams, returned, lookup) -> assoc list (uses :catalog_item_id)
    * `:content_type` - Content type string for catalog_items (e.g., "movie")
    * `:type` - Content type atom for telemetry (optional, e.g., :live, :movies)
    * `:provider` - Provider struct for telemetry (optional)
  """
  def upsert_content_batched(streams, provider_id, category_lookup, now, opts) do
    schema = Keyword.fetch!(opts, :schema)
    attrs_fn = Keyword.fetch!(opts, :attrs_fn)
    category_fn = Keyword.fetch!(opts, :category_fn)
    catalog_content_type = Keyword.fetch!(opts, :content_type)

    # Optional telemetry context
    telemetry_type = Keyword.get(opts, :type)
    provider = Keyword.get(opts, :provider)

    # Determine the stream_id field based on schema
    stream_id_field = if schema == Streamix.Iptv.Series, do: :series_id, else: :stream_id

    total_batches = ceil(length(streams) / @batch_size)

    # Build set of existing stream_ids for this provider (to know which need catalog_items)
    existing_stream_ids =
      schema
      |> where(provider_id: ^provider_id)
      |> select([c], field(c, ^stream_id_field))
      |> Repo.all()
      |> MapSet.new()

    streams
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce({0, []}, fn {batch, batch_num}, {acc_count, acc_ids} ->
      batch_start = System.monotonic_time()

      # Find NEW stream_ids in this batch that don't exist yet
      stream_id_key = if stream_id_field == :series_id, do: "series_id", else: "stream_id"

      new_stream_ids =
        batch
        |> Enum.map(& &1[stream_id_key])
        |> Enum.reject(&MapSet.member?(existing_stream_ids, &1))

      # Pre-create catalog_items for new rows
      new_catalog_item_ids =
        pre_create_catalog_items(length(new_stream_ids), catalog_content_type, provider_id, now)

      # Build mapping: new stream_id -> catalog_item_id
      new_ci_map = Enum.zip(new_stream_ids, new_catalog_item_ids) |> Map.new()

      # Get existing catalog_item_ids for existing rows
      existing_sids =
        batch
        |> Enum.map(& &1[stream_id_key])
        |> Enum.filter(&MapSet.member?(existing_stream_ids, &1))

      existing_ci_map =
        fetch_existing_ci_map(schema, provider_id, stream_id_field, existing_sids)

      ci_map = Map.merge(existing_ci_map, new_ci_map)

      content_data =
        Enum.map(batch, fn stream ->
          sid = stream[stream_id_key]
          attrs = attrs_fn.(stream, provider_id, now)
          Map.put(attrs, :catalog_item_id, ci_map[sid])
        end)

      {inserted, returned} =
        Repo.insert_all(schema, content_data,
          on_conflict: {:replace_all_except, [:id, :inserted_at, :catalog_item_id]},
          conflict_target: [:provider_id, stream_id_field],
          returning: [:id, stream_id_field, :catalog_item_id]
        )

      # Rebuild category associations via item_categories
      catalog_item_ids = Enum.map(returned, & &1.catalog_item_id) |> Enum.reject(&is_nil/1)
      category_assocs = category_fn.(batch, returned, category_lookup)

      rebuild_category_assocs_diff(catalog_item_ids, category_assocs)

      # Emit batch telemetry if provider context available
      if provider && telemetry_type do
        batch_duration = System.monotonic_time() - batch_start

        :telemetry.execute(
          [:streamix, :sync, :batch],
          %{count: inserted, duration: batch_duration},
          %{provider_id: provider.id, type: telemetry_type, batch_number: batch_num}
        )

        percent = round(batch_num / total_batches * 100)

        :telemetry.execute(
          [:streamix, :sync, :batch_progress],
          %{percent: percent, batch: batch_num, total_batches: total_batches},
          %{provider_id: provider.id, type: telemetry_type}
        )
      end

      batch_stream_ids = Enum.map(batch, & &1[stream_id_key])
      {acc_count + inserted, batch_stream_ids ++ acc_ids}
    end)
    |> then(fn {count, ids} -> {count, Enum.reverse(ids)} end)
  end

  defp fetch_existing_ci_map(_schema, _provider_id, _stream_id_field, []), do: %{}

  defp fetch_existing_ci_map(schema, provider_id, stream_id_field, existing_sids) do
    schema
    |> where(provider_id: ^provider_id)
    |> where([c], field(c, ^stream_id_field) in ^existing_sids)
    |> select([c], {field(c, ^stream_id_field), c.catalog_item_id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Pre-creates N catalog_items of the given content_type and returns their IDs.
  """
  def pre_create_catalog_items(0, _content_type, _provider_id, _now), do: []

  def pre_create_catalog_items(count, content_type, provider_id, now) do
    entries =
      for _ <- 1..count do
        %{content_type: content_type, provider_id: provider_id, inserted_at: now, updated_at: now}
      end

    {_count, items} = Repo.insert_all(CatalogItem, entries, returning: [:id])
    Enum.map(items, & &1.id)
  end

  @doc """
  Generic orphan deletion for content types.

  Deletion order matters because of foreign key constraints:

    1. `item_categories` (associations only)
    2. `movies` / `series` (they reference `catalog_items.id`)
    3. `catalog_items` (now safe — no inbound refs)

  An earlier version tried to delete `catalog_items` before the content
  rows and produced FK violations on every sync, which silently aborted
  cleanup — leaving "ghost" titles that the upstream provider had
  already removed (Choki removes channels/movies frequently). Step
  ordering matters: don't reorder.

  ## Options
    * `:schema` - The Ecto schema module
    * `:table_name` - Main table name (e.g., "movies")
  """
  def delete_orphaned_content(provider_id, current_stream_ids, opts) do
    schema = Keyword.fetch!(opts, :schema)
    table_name = Keyword.fetch!(opts, :table_name)

    # 1. item_categories first — only references catalog_item_id
    Repo.query!(
      """
      DELETE FROM item_categories
      WHERE catalog_item_id IN (
        SELECT catalog_item_id FROM #{table_name}
        WHERE provider_id = $1 AND stream_id != ALL($2)
      )
      """,
      [provider_id, current_stream_ids]
    )

    # 2. Capture orphan catalog_item ids BEFORE deleting the content rows,
    # so we can clean those catalog_items afterwards (we lose the join
    # the moment the rows are gone).
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT catalog_item_id FROM #{table_name}
        WHERE provider_id = $1 AND stream_id != ALL($2)
        """,
        [provider_id, current_stream_ids]
      )

    orphan_catalog_ids = Enum.map(rows, fn [id] -> id end)

    # 3. Delete the orphaned content rows
    {count, _} =
      schema
      |> where([c], c.provider_id == ^provider_id)
      |> where([c], c.stream_id not in ^current_stream_ids)
      |> Repo.delete_all()

    # 4. Now safe to remove the catalog_items they pointed at
    if orphan_catalog_ids != [] do
      Repo.query!(
        "DELETE FROM catalog_items WHERE id = ANY($1)",
        [orphan_catalog_ids]
      )
    end

    count
  end

  @doc """
  Builds category associations from streams and returned entities.
  Uses `catalog_item_id` from returned entities for `item_categories` table.
  """
  def build_category_assocs(streams, returned_entities, category_lookup, _opts \\ []) do
    stream_to_ci_id =
      Map.new(returned_entities, fn entity ->
        sid = Map.get(entity, :stream_id) || Map.get(entity, :series_id)
        {sid, entity.catalog_item_id}
      end)

    streams
    |> Enum.flat_map(fn stream ->
      sid = stream["stream_id"] || stream["series_id"]
      ci_id = stream_to_ci_id[sid]
      cat_ext_id = to_string(stream["category_id"])
      category_id = category_lookup[cat_ext_id]

      if ci_id && category_id do
        [%{catalog_item_id: ci_id, category_id: category_id}]
      else
        []
      end
    end)
  end

  @doc """
  Ensures every content row has a catalog_item.
  Creates catalog_items for rows that don't have one yet.

  NOTE: With NOT NULL catalog_item_id, this is only needed for legacy data
  or GIndex sync paths that don't use upsert_content_batched.
  """
  def ensure_catalog_items(table_name, content_type, provider_id)
      when is_binary(table_name) and is_binary(content_type) do
    Repo.query!(
      """
        WITH missing AS (
          SELECT id FROM #{table_name} WHERE catalog_item_id IS NULL
        ),
        new_items AS (
          INSERT INTO catalog_items (content_type, provider_id, inserted_at, updated_at)
          SELECT $1, $2, NOW(), NOW()
          FROM missing
          RETURNING id
        ),
        numbered_new AS (
          SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM new_items
        ),
        numbered_content AS (
          SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM missing
        )
        UPDATE #{table_name} c
        SET catalog_item_id = nn.id
        FROM numbered_content nc
        JOIN numbered_new nn ON nc.rn = nn.rn
        WHERE c.id = nc.id
      """,
      [content_type, provider_id]
    )

    :ok
  end

  @doc """
  Syncs genres and credits (cast/director) for a batch of content.

  Parses comma-separated genre/cast/director strings from raw API data,
  upserts genres and people, then creates junction table entries.

  ## Options
    * `:credits_table` - Credits table name (e.g., "movie_credits")
    * `:stream_id_key` - Key in the raw stream map for the stream ID (default: "stream_id")
  """
  def sync_genres_and_credits(streams, provider_id, schema, genre_join_table, fk_column, opts) do
    credits_table = Keyword.fetch!(opts, :credits_table)
    stream_id_key = Keyword.get(opts, :stream_id_key, "stream_id")
    fk_col_atom = String.to_existing_atom(fk_column)
    stream_id_field = if fk_column == "series_id", do: :series_id, else: :stream_id

    db_lookup = build_db_lookup(schema, provider_id, stream_id_field)

    genre_map = streams |> extract_unique_names("genre") |> upsert_genres()
    people_map = extract_all_people(streams) |> upsert_people()

    build_genre_assocs(streams, db_lookup, genre_map, stream_id_key, fk_col_atom)
    |> batch_insert(genre_join_table)

    build_credit_assocs(streams, db_lookup, people_map, stream_id_key, fk_col_atom)
    |> batch_insert(credits_table)

    :ok
  end

  defp build_db_lookup(schema, provider_id, stream_id_field) do
    schema
    |> where(provider_id: ^provider_id)
    |> select([c], {field(c, ^stream_id_field), c.id})
    |> Repo.all()
    |> Map.new()
  end

  defp extract_all_people(streams) do
    cast = extract_unique_names(streams, "cast")
    directors = extract_unique_names(streams, "director")
    MapSet.union(cast, directors)
  end

  defp build_genre_assocs(streams, db_lookup, genre_map, stream_id_key, fk_col_atom) do
    Enum.flat_map(streams, fn stream ->
      case Map.get(db_lookup, stream[stream_id_key]) do
        nil ->
          []

        db_id ->
          stream["genre"]
          |> parse_comma_separated()
          |> Enum.flat_map(&resolve_genre(&1, genre_map, fk_col_atom, db_id))
      end
    end)
  end

  defp resolve_genre(name, genre_map, fk_col_atom, db_id) do
    case Map.get(genre_map, String.downcase(name)) do
      nil -> []
      genre_id -> [%{fk_col_atom => db_id, genre_id: genre_id}]
    end
  end

  defp build_credit_assocs(streams, db_lookup, people_map, stream_id_key, fk_col_atom) do
    Enum.flat_map(streams, fn stream ->
      case Map.get(db_lookup, stream[stream_id_key]) do
        nil ->
          []

        db_id ->
          cast = build_role_credits(stream["cast"], people_map, fk_col_atom, db_id, "cast")

          dirs =
            build_role_credits(stream["director"], people_map, fk_col_atom, db_id, "director")

          cast ++ dirs
      end
    end)
  end

  defp build_role_credits(raw, people_map, fk_col_atom, db_id, role) do
    raw
    |> parse_comma_separated()
    |> Enum.with_index()
    |> Enum.flat_map(fn {name, idx} ->
      case Map.get(people_map, String.downcase(name)) do
        nil -> []
        person_id -> [%{fk_col_atom => db_id, person_id: person_id, role: role, position: idx}]
      end
    end)
  end

  defp batch_insert([], _table), do: :ok

  defp batch_insert(assocs, table) do
    assocs
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&Repo.insert_all(table, &1, on_conflict: :nothing))
  end

  defp extract_unique_names(streams, field) do
    streams
    |> Enum.flat_map(fn stream ->
      parse_comma_separated(stream[field])
    end)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp parse_comma_separated(nil), do: []
  defp parse_comma_separated(""), do: []

  defp parse_comma_separated(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp upsert_genres(names) when is_struct(names, MapSet) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      names
      |> Enum.map(fn name -> %{name: name, inserted_at: now, updated_at: now} end)

    if entries != [] do
      entries
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(fn batch ->
        Repo.insert_all(Genre, batch, on_conflict: :nothing)
      end)
    end

    Genre
    |> select([g], {fragment("lower(?)", g.name), g.id})
    |> Repo.all()
    |> Map.new()
  end

  defp upsert_people(names) when is_struct(names, MapSet) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      names
      |> Enum.map(fn name -> %{name: name, inserted_at: now, updated_at: now} end)

    if entries != [] do
      entries
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(fn batch ->
        Repo.insert_all(Person, batch, on_conflict: :nothing)
      end)
    end

    Person
    |> select([p], {fragment("lower(?)", p.name), p.id})
    |> Repo.all()
    |> Map.new()
  end
end
