defmodule StreamixWeb.Content.TitleIdentity do
  @moduledoc """
  Tells provider copies of one title apart from different titles.

  Every provider stores its own copy of a movie or series, so a recommendation
  or similarity lookup can return the same title several times ("Farol da
  Ilusão" and "Farol da Ilusão [L]"). Rails show one card per title and leave
  the copies to the source picker on the detail page.

  Two rows are the same title when they share a TMDB or IMDb id, or when their
  display titles match and their years do not contradict each other (a remake
  with another year stays a different title).
  """

  alias StreamixWeb.Content.DisplayTitle

  @doc """
  Keeps the first row of each title, in order, and drops every title of
  `exclude` (the page's own title, for instance).
  """
  @spec distinct([map()], [map()]) :: [map()]
  def distinct(items, exclude \\ []) do
    seen = Enum.reduce(exclude, empty(), &remember(&2, &1))

    {kept, _seen} =
      Enum.reduce(items, {[], seen}, fn item, {kept, seen} ->
        if seen?(seen, item),
          do: {kept, seen},
          else: {[item | kept], remember(seen, item)}
      end)

    Enum.reverse(kept)
  end

  defp empty, do: %{ids: MapSet.new(), titles: %{}}

  defp seen?(seen, item) do
    Enum.any?(external_ids(item), &MapSet.member?(seen.ids, &1)) or
      title_seen?(Map.get(seen.titles, title_key(item)), year(item))
  end

  defp title_seen?(nil, _year), do: false
  defp title_seen?(_years, nil), do: true
  defp title_seen?(years, year), do: MapSet.member?(years, nil) or MapSet.member?(years, year)

  defp remember(seen, item) do
    ids = Enum.into(external_ids(item), seen.ids)

    titles =
      case title_key(item) do
        "" -> seen.titles
        key -> Map.update(seen.titles, key, MapSet.new([year(item)]), &MapSet.put(&1, year(item)))
      end

    %{ids: ids, titles: titles}
  end

  defp external_ids(item) do
    for {field, tag} <- [tmdb_id: :tmdb, imdb_id: :imdb],
        id = present(Map.get(item, field)),
        do: {tag, id}
  end

  defp title_key(item), do: item |> DisplayTitle.title() |> String.downcase()

  defp year(item) do
    case Map.get(item, :year) do
      year when is_integer(year) and year > 0 -> year
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value) when is_integer(value), do: Integer.to_string(value)
  defp present(_value), do: nil
end
