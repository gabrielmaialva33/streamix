defmodule Streamix.Iptv.Credits do
  @moduledoc """
  Finds the people a free-text query names and the titles they made.

  "filmes do christopher nolan" or "tom hanks anos 90" leave a name in the
  discovery parser's `:terms`; every run of two to four consecutive words is
  looked up against the credited people (stored lowercased, as provider sync
  and TMDB credits write them). A single word is never treated as a name:
  "nolan" alone would also be a dozen other people.

  A person's titles are the ones they directed or wrote, or where they are
  billed among the first eight of the cast.
  """

  import Ecto.Query, warn: false

  alias Streamix.Repo

  @max_words 4
  @billing 8
  @title_limit 400

  @type t :: %{people: [String.t()], movies: [String.t()], series: [String.t()]}

  @doc """
  The people named in `text` (display names) and the variant keys of their
  movies and series. Empty lists when nobody is named.
  """
  @spec titles_by_people(String.t() | nil) :: t()
  def titles_by_people(text) when is_binary(text) do
    case text |> phrases() |> people() do
      [] ->
        %{people: [], movies: [], series: []}

      people ->
        ids = Enum.map(people, &elem(&1, 0))

        %{
          people: Enum.map(people, &display_name(elem(&1, 1))),
          movies: variant_keys("movie_credits", "movies", "movie_id", ids),
          series: variant_keys("series_credits", "series", "series_id", ids)
        }
    end
  end

  def titles_by_people(_text), do: %{people: [], movies: [], series: []}

  defp phrases(text) do
    words = text |> String.downcase() |> String.split(~r/[^\p{L}\p{N}'.-]+/u, trim: true)

    for size <- 2..@max_words//1,
        start <- 0..(length(words) - size)//1,
        size <= length(words),
        uniq: true,
        do: words |> Enum.slice(start, size) |> Enum.join(" ")
  end

  # Longer names win when one contains another ("john david washington"
  # over "david washington").
  defp people([]), do: []

  defp people(phrases) do
    found =
      Repo.all(from(p in "people", where: p.name in ^phrases, select: {p.id, p.name}))

    Enum.reject(found, fn {_id, name} ->
      Enum.any?(found, fn {_other, longer} ->
        longer != name and String.contains?(longer, name)
      end)
    end)
  end

  defp variant_keys(credits, content, fk, person_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.variant_key
        FROM #{credits} cr
        JOIN #{content} c ON c.id = cr.#{fk}
        WHERE cr.person_id = ANY($1)
          AND (cr.role IN ('director', 'writer') OR cr.position < $2)
          AND c.variant_key IS NOT NULL
        GROUP BY c.variant_key
        ORDER BY min(CASE cr.role WHEN 'director' THEN 0 WHEN 'writer' THEN 1 ELSE 2 END),
                 max(c.rating) DESC NULLS LAST
        LIMIT $3
        """,
        [person_ids, @billing, @title_limit]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "A stored lowercased name in display case."
  @spec display_name(String.t()) :: String.t()
  def display_name(name) do
    name |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)
  end
end
