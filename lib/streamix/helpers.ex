defmodule Streamix.Helpers do
  @moduledoc """
  Common helper functions used across the application.
  """

  @doc """
  Escapes special characters in a string for use in SQL LIKE/ILIKE patterns.

  Prevents SQL injection by escaping `%`, `_`, and `\\` characters
  that have special meaning in LIKE patterns.

  ## Examples

      iex> Streamix.Helpers.escape_like("foo%bar")
      "foo\\%bar"

      iex> Streamix.Helpers.escape_like("test_123")
      "test\\_123"

      iex> Streamix.Helpers.escape_like("normal")
      "normal"
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  def escape_like(nil), do: ""

  # =============================================================================
  # Content Formatting (genres, credits)
  # =============================================================================

  @doc """
  Formats a list of Genre structs as a comma-separated string, ordered by
  `position` (nil last) then `name`.
  Returns nil if the list is empty or not loaded.

  ## Examples

      iex> Streamix.Helpers.genre_names([%{name: "Drama", position: 7}, %{name: "Ação", position: 1}])
      "Ação, Drama"

      iex> Streamix.Helpers.genre_names([])
      nil
  """
  @spec genre_names(list() | Ecto.Association.NotLoaded.t() | nil) :: String.t() | nil
  def genre_names(%Ecto.Association.NotLoaded{}), do: nil
  def genre_names(nil), do: nil
  def genre_names([]), do: nil

  def genre_names(genres) when is_list(genres) do
    genres
    |> sort_genres()
    |> Enum.map_join(", ", & &1.name)
  end

  @doc """
  Formats a list of Genre structs into API genre references (`[%{slug: slug, name: name}]`),
  keeping only canonical genres with a non-empty `slug` and ordering by `position`
  (nil last) then `name`.

  ## Examples

      iex> Streamix.Helpers.genre_refs([%{slug: "drama", name: "Drama", position: 7}, %{slug: "acao", name: "Ação", position: 1}])
      [%{slug: "acao", name: "Ação"}, %{slug: "drama", name: "Drama"}]

      iex> Streamix.Helpers.genre_refs([])
      []
  """
  @spec genre_refs(list() | Ecto.Association.NotLoaded.t() | nil) :: [
          %{slug: String.t(), name: String.t()}
        ]
  def genre_refs(%Ecto.Association.NotLoaded{}), do: []
  def genre_refs(nil), do: []
  def genre_refs([]), do: []

  def genre_refs(genres) when is_list(genres) do
    genres
    |> Enum.filter(&has_slug?/1)
    |> sort_genres()
    |> Enum.map(&%{slug: &1.slug, name: &1.name})
  end

  defp has_slug?(%{slug: slug}) when is_binary(slug) and slug != "", do: true
  defp has_slug?(_genre), do: false

  defp sort_genres(genres) do
    Enum.sort_by(genres, fn genre ->
      position = Map.get(genre, :position)
      {is_nil(position), position || 0, Map.get(genre, :name) || ""}
    end)
  end

  @doc """
  Extracts cast names from credits, sorted by position.
  Returns a comma-separated string or nil.
  """
  @spec cast_names(list()) :: String.t() | nil
  def cast_names(%Ecto.Association.NotLoaded{}), do: nil
  def cast_names(nil), do: nil
  def cast_names([]), do: nil

  def cast_names(credits) when is_list(credits) do
    result =
      credits
      |> Enum.filter(&(&1.role == "cast"))
      |> Enum.sort_by(& &1.position)
      |> Enum.map_join(", ", & &1.person.name)

    if result == "", do: nil, else: result
  end

  @doc """
  Extracts director names from credits.
  Returns a comma-separated string or nil.
  """
  @spec director_names(list()) :: String.t() | nil
  def director_names(%Ecto.Association.NotLoaded{}), do: nil
  def director_names(nil), do: nil
  def director_names([]), do: nil

  def director_names(credits) when is_list(credits) do
    result =
      credits
      |> Enum.filter(&(&1.role == "director"))
      |> Enum.map_join(", ", & &1.person.name)

    if result == "", do: nil, else: result
  end
end
