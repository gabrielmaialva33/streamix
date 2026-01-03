defmodule Streamix.Iptv.Sync.Helpers do
  @moduledoc """
  Shared helper functions for sync operations.
  Provides parsing utilities and category lookup building.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Category
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
  Normalizes backdrop paths to a list format.
  """
  def normalize_backdrop(nil), do: nil
  def normalize_backdrop(list) when is_list(list), do: list
  def normalize_backdrop(str) when is_binary(str), do: [str]

  @doc """
  Converts a value to string or returns nil.
  """
  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(val), do: to_string(val)

  # =============================================================================
  # Diff-based Category Association Rebuild
  # =============================================================================

  @doc """
  Rebuilds category associations using diff-based strategy.

  Instead of deleting all associations and re-inserting (which causes WAL bloat
  and momentary visibility gaps), this function:

  1. Fetches current associations from DB
  2. Computes the diff (what to add, what to remove)
  3. Only deletes obsolete associations
  4. Only inserts new associations

  ## Parameters

    * `table` - The join table name (e.g., "movie_categories")
    * `fk_column` - The foreign key column name (e.g., "movie_id")
    * `cat_column` - The category column name (e.g., "category_id")
    * `entity_ids` - List of entity IDs being synced
    * `desired_assocs` - List of desired association maps (e.g., [%{movie_id: 1, category_id: 2}])

  ## Example

      rebuild_category_assocs_diff(
        "movie_categories",
        "movie_id",
        "category_id",
        [1, 2, 3],
        [%{movie_id: 1, category_id: 10}, %{movie_id: 2, category_id: 20}]
      )

  """
  def rebuild_category_assocs_diff(table, fk_column, cat_column, entity_ids, desired_assocs)
      when is_binary(table) and is_binary(fk_column) and is_list(entity_ids) do
    if Enum.empty?(entity_ids) do
      :ok
    else
      do_rebuild_diff(table, fk_column, cat_column, entity_ids, desired_assocs)
    end
  end

  defp do_rebuild_diff(table, fk_column, cat_column, entity_ids, desired_assocs) do
    # 1. Fetch current associations from DB
    current_assocs =
      Repo.query!(
        "SELECT #{fk_column}, #{cat_column} FROM #{table} WHERE #{fk_column} = ANY($1)",
        [entity_ids]
      )
      |> Map.get(:rows, [])
      |> MapSet.new(fn [entity_id, category_id] -> {entity_id, category_id} end)

    # 2. Build desired associations as MapSet
    desired_set =
      desired_assocs
      |> Enum.map(fn assoc ->
        entity_id = Map.get(assoc, String.to_existing_atom(fk_column))
        category_id = Map.get(assoc, String.to_existing_atom(cat_column))
        {entity_id, category_id}
      end)
      |> Enum.reject(fn {e, c} -> is_nil(e) or is_nil(c) end)
      |> MapSet.new()

    # 3. Compute diff
    to_insert = MapSet.difference(desired_set, current_assocs)
    to_delete = MapSet.difference(current_assocs, desired_set)

    # 4. Bulk delete obsolete associations
    unless MapSet.size(to_delete) == 0 do
      delete_pairs = MapSet.to_list(to_delete)
      bulk_delete_assocs(table, fk_column, cat_column, delete_pairs)
    end

    # 5. Insert new associations
    unless MapSet.size(to_insert) == 0 do
      fk_atom = String.to_existing_atom(fk_column)
      cat_atom = String.to_existing_atom(cat_column)

      new_assocs =
        to_insert
        |> MapSet.to_list()
        |> Enum.map(fn {entity_id, category_id} ->
          %{fk_atom => entity_id, cat_atom => category_id}
        end)

      Repo.insert_all(table, new_assocs)
    end

    :ok
  end

  defp bulk_delete_assocs(table, fk_column, cat_column, pairs) do
    # Build parameterized VALUES clause for safe deletion
    values_clause =
      pairs
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_, i} -> "($#{i * 2 - 1}::bigint, $#{i * 2}::bigint)" end)

    params = Enum.flat_map(pairs, fn {entity_id, cat_id} -> [entity_id, cat_id] end)

    Repo.query!(
      """
      DELETE FROM #{table}
      WHERE (#{fk_column}, #{cat_column}) IN (VALUES #{values_clause})
      """,
      params
    )
  end
end
