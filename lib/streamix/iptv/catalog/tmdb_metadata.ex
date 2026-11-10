defmodule Streamix.Iptv.TmdbMetadata do
  @moduledoc """
  Stores what TMDB says about a title beyond its genres: its keywords and the
  credits people search by (billed cast, directors, writers).

  Like `Streamix.Iptv.Genres.apply_tmdb/3`, one fetched answer is applied to
  every provider copy carrying that `tmdb_id`. `tmdb_keyword_ids` doubles as
  the "fetched" marker: NULL is pending, an empty array is an answer.

  People are keyed by their lowercased name, the convention provider sync
  already uses, so a TMDB credit and a provider credit for the same person
  land on the same row. Adult copies get the marker but no credits, so a
  person's filmography never lists them.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.Person
  alias Streamix.Iptv.TmdbClient.Parser
  alias Streamix.Repo

  @kinds %{
    movies: %{content: "movies", credits: "movie_credits", fk: "movie_id"},
    series: %{content: "series", credits: "series_credits", fk: "series_id"}
  }

  @doc """
  Stores keywords and credits on every copy of a TMDB title, in one
  transaction. Returns how many copies were stamped and credits added.
  """
  @spec apply_tmdb(:movies | :series, String.t() | integer(), %{
          required(:keywords) => [Parser.keyword_tag()],
          required(:credits) => [Parser.credit()],
          optional(atom()) => term()
        }) :: {:ok, %{copies: non_neg_integer(), credits: non_neg_integer()}} | {:error, term()}
  def apply_tmdb(kind, tmdb_id, %{keywords: keywords, credits: credits})
      when kind in [:movies, :series] and is_list(keywords) and is_list(credits) and
             ((is_binary(tmdb_id) and tmdb_id != "") or (is_integer(tmdb_id) and tmdb_id > 0)) do
    config = Map.fetch!(@kinds, kind)

    Repo.transaction(
      fn ->
        upsert_keywords(keywords)
        person_ids = upsert_people(credits)
        store(config, to_string(tmdb_id), Enum.map(keywords, & &1.id), credits, person_ids)
      end,
      timeout: :timer.minutes(1)
    )
  end

  @doc "Keyword names by id, for the ids given; unknown ids are left out."
  @spec keyword_names([integer()]) :: %{integer() => String.t()}
  def keyword_names([]), do: %{}

  def keyword_names(ids) when is_list(ids) do
    Repo.all(from(k in "tmdb_keywords", where: k.id in ^ids, select: {k.id, k.name}))
    |> Map.new()
  end

  defp upsert_keywords([]), do: :ok

  defp upsert_keywords(keywords) do
    now = DateTime.utc_now(:second)
    rows = Enum.map(keywords, &%{id: &1.id, name: &1.name, inserted_at: now})

    Repo.insert_all("tmdb_keywords", rows, on_conflict: {:replace, [:name]}, conflict_target: :id)
    :ok
  end

  defp upsert_people([]), do: %{}

  defp upsert_people(credits) do
    now = DateTime.utc_now(:second)
    names = credits |> Enum.map(&person_key/1) |> Enum.uniq()
    rows = Enum.map(names, &%{name: &1, inserted_at: now, updated_at: now})

    Repo.insert_all(Person, rows, on_conflict: :nothing, conflict_target: :name)

    Repo.all(from(p in Person, where: p.name in ^names, select: {p.name, p.id}))
    |> Map.new()
  end

  defp store(config, tmdb_id, keyword_ids, credits, person_ids) do
    %{content: content, credits: table, fk: fk} = config

    {people, roles, positions} =
      credits
      |> Enum.flat_map(fn credit ->
        case Map.fetch(person_ids, person_key(credit)) do
          {:ok, id} -> [{id, credit.role, credit.position}]
          :error -> []
        end
      end)
      |> unzip3()

    %{rows: [[copies, added]]} =
      Repo.query!(
        """
        WITH items AS (
          SELECT c.id, c.catalog_item_id FROM #{content} c
          WHERE c.tmdb_id = $1 AND c.tmdb_id <> ''
          ORDER BY c.id FOR NO KEY UPDATE OF c
        ),
        added AS (
          INSERT INTO #{table} (#{fk}, person_id, role, position)
          SELECT i.id, cr.person_id, cr.role, cr.position
          FROM items i
          CROSS JOIN unnest($3::bigint[], $4::text[], $5::integer[]) AS cr(person_id, role, position)
          WHERE NOT EXISTS (
            SELECT 1 FROM item_categories ic JOIN categories k ON k.id = ic.category_id
            WHERE ic.catalog_item_id = i.catalog_item_id AND k.is_adult
          )
          ON CONFLICT DO NOTHING RETURNING 1
        ),
        stamped AS (
          UPDATE #{content} c SET tmdb_keyword_ids = $2::integer[]
          FROM items i WHERE c.id = i.id RETURNING 1
        )
        SELECT (SELECT count(*) FROM stamped), (SELECT count(*) FROM added)
        """,
        [tmdb_id, keyword_ids, people, roles, positions]
      )

    %{copies: copies, credits: added}
  end

  defp person_key(%{name: name}), do: name |> String.trim() |> String.downcase()

  defp unzip3(triples) do
    Enum.reduce(Enum.reverse(triples), {[], [], []}, fn {a, b, c}, {as, bs, cs} ->
      {[a | as], [b | bs], [c | cs]}
    end)
  end
end
