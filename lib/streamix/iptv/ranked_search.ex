defmodule Streamix.Iptv.RankedSearch do
  @moduledoc """
  Fuzzy + ranked lexical search for the public catalog.

  Traditional `ILIKE '%query%'` works, but it's a cliff function — either
  the substring is there or it isn't, and every match is considered
  equal. On a TV remote where users mistype all the time, that's the
  wrong UX. This module layers four signals on top of ILIKE to produce
  a stable ordering that matches what the viewer expects:

    * **Exact match**  (1000) — `"Matrix"` searches return Matrix first.
    * **Prefix match** (500)  — `"Mat"` surfaces anything starting with
      "Mat" before titles that merely contain it.
    * **Substring**    (200)  — the classic ILIKE behaviour, kept as a
      third tier so it still matters for partial words like `"evil"`
      finding "Resident Evil".
    * **Trigram**      (0-100) — `pg_trgm`'s `similarity/2` catches
      typos (`"Matris"` → `"Matrix"`) and diacritic-free queries
      (`"pokemon"` → `"Pokémon"`) via the `unaccent` wrapper. Scored
      1-100 so a fuzzy hit never outranks a literal one.

  The column being searched is `unaccent`-folded on both sides before
  every comparison so a query like `"pokemon"` matches `"Pokémon"`
  without the caller needing to normalise anything client-side.

  ## Usage

      Movie
      |> Access.public_providers()
      |> RankedSearch.build([:name, :title], query, limit: 20)
      |> Repo.all()

  `build/4` stitches a `rank_score` column onto the query via
  `select_merge`, filters out rows below the minimum score, and orders
  by score desc then rating desc then name asc. Callers finish with a
  single `Repo.all/1`.

  Requires `pg_trgm` and `unaccent` extensions — see the corresponding
  migrations under `priv/repo/migrations/`.
  """

  import Ecto.Query

  @default_min_score 30

  @type opts :: [
          limit: pos_integer(),
          min_score: non_neg_integer(),
          rating_field: atom() | false,
          name_field: atom()
        ]

  @doc """
  Builds a ranked search query against one or two columns.

  Two-column mode takes the higher of the per-column scores so a title
  match can still win when the primary `name` field doesn't contain
  the query.

  Options:
    * `:limit`        — cap on the result set (required)
    * `:min_score`    — floor the rank must clear to appear (default #{@default_min_score})
    * `:rating_field` — field used as secondary sort; `false` to skip
    * `:name_field`   — final alphabetical tie-break (default `:name`)
  """
  @spec build(Ecto.Queryable.t(), [atom()], String.t(), opts()) :: Ecto.Query.t()
  def build(queryable, fields, raw_query, opts) when is_list(fields) and fields != [] do
    q = normalize_query(raw_query)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    rating_field = Keyword.get(opts, :rating_field, :rating)
    name_field = Keyword.get(opts, :name_field, :name)
    limit = Keyword.fetch!(opts, :limit)

    # Postgres won't accept a SELECT alias in the WHERE clause, but does
    # accept it in ORDER BY. The score-containing query becomes the inner
    # `FROM (...)` of an outer query that filters, orders, and limits.
    inner =
      queryable
      |> score_select(fields, q)
      |> order_by_score(rating_field, name_field)

    from(row in subquery(inner),
      where: row.rank_score >= ^min_score,
      limit: ^limit
    )
  end

  # One-column pipeline. Straightforward CASE + similarity — used by
  # channels, which don't have a title field.
  defp score_select(queryable, [field1], q) do
    from(row in queryable,
      select_merge: %{
        rank_score:
          selected_as(
            fragment(
              """
              GREATEST(
                CASE WHEN lower(unaccent(?)) = ? THEN 1000 ELSE 0 END,
                CASE WHEN lower(unaccent(?)) LIKE ? THEN 500 ELSE 0 END,
                CASE WHEN lower(unaccent(?)) LIKE ? THEN 200 ELSE 0 END,
                (similarity(lower(unaccent(?)), ?) * 100)::int
              )
              """,
              field(row, ^field1),
              ^q,
              field(row, ^field1),
              ^(q <> "%"),
              field(row, ^field1),
              ^("%" <> q <> "%"),
              field(row, ^field1),
              ^q
            ),
            :rank_score
          )
      }
    )
  end

  # Two-column pipeline. Emits one big GREATEST over both columns so a
  # stronger signal on either wins for that row. The COALESCE(?, '')
  # guard is there because title is NULLable on many movies/series.
  defp score_select(queryable, [field1, field2], q) do
    from(row in queryable,
      select_merge: %{
        rank_score:
          selected_as(
            fragment(
              """
              GREATEST(
                CASE WHEN lower(unaccent(?)) = ? THEN 1000 ELSE 0 END,
                CASE WHEN lower(unaccent(?)) LIKE ? THEN 500 ELSE 0 END,
                CASE WHEN lower(unaccent(?)) LIKE ? THEN 200 ELSE 0 END,
                (similarity(lower(unaccent(?)), ?) * 100)::int,
                CASE WHEN lower(unaccent(COALESCE(?, ''))) = ? THEN 1000 ELSE 0 END,
                CASE WHEN lower(unaccent(COALESCE(?, ''))) LIKE ? THEN 500 ELSE 0 END,
                CASE WHEN lower(unaccent(COALESCE(?, ''))) LIKE ? THEN 200 ELSE 0 END,
                (similarity(lower(unaccent(COALESCE(?, ''))), ?) * 100)::int
              )
              """,
              field(row, ^field1),
              ^q,
              field(row, ^field1),
              ^(q <> "%"),
              field(row, ^field1),
              ^("%" <> q <> "%"),
              field(row, ^field1),
              ^q,
              field(row, ^field2),
              ^q,
              field(row, ^field2),
              ^(q <> "%"),
              field(row, ^field2),
              ^("%" <> q <> "%"),
              field(row, ^field2),
              ^q
            ),
            :rank_score
          )
      }
    )
  end

  defp order_by_score(query, false, name_field) do
    order_by(query, [row], desc: selected_as(:rank_score), asc: field(row, ^name_field))
  end

  defp order_by_score(query, rating_field, name_field) do
    # Rating is NULLable on a lot of catalogue rows; pushing nulls last
    # keeps untagged content below the ranked matches of the same score.
    order_by(query, [row],
      desc: selected_as(:rank_score),
      asc: fragment("? DESC NULLS LAST", field(row, ^rating_field)),
      asc: field(row, ^name_field)
    )
  end

  @doc """
  Normalises a raw user query into the form the SQL CASE expects
  (lowercased, unaccent-equivalent). Exposed for tests.
  """
  @spec normalize_query(String.t()) :: String.t()
  def normalize_query(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end
end
