defmodule StreamixWeb.Content.HelperComponents do
  @moduledoc "Shared private formatting functions for content components."
  alias StreamixWeb.Helpers.ImageProxy

  def format_count(nil), do: nil

  def format_count(count) when count >= 1000 do
    "#{Float.round(count / 1000, 1)}k"
  end

  def format_count(count), do: to_string(count)

  def format_rating(%Decimal{} = rating) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  def display_year(year) when is_integer(year) and year > 0, do: year
  def display_year(_), do: ""

  def format_duration(nil), do: nil
  def format_duration(0), do: nil

  def format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)

    if hours > 0, do: "#{hours}h #{minutes}min", else: "#{minutes}min"
  end

  def format_duration(_), do: nil

  def format_genre_names(content) do
    case Map.get(content, :genres, []) do
      genres when is_list(genres) and genres != [] ->
        Enum.map_join(genres, ", ", & &1.name)

      _ ->
        nil
    end
  end

  @doc """
  Label for an episode row: the stored title, then the stored name, then a
  numbered fallback — each run through the gindex cleaner.

  Title comes first because `name` is the raw filename for 102.209 of the
  104.975 episodes in the catalog, and a filename is never a better label than
  a title. The cleaner still runs on the title, since the provider's own parse
  leaves scene tokens behind on some of them.
  """
  def episode_title(episode) do
    raw =
      present(Map.get(episode, :title)) ||
        present(Map.get(episode, :name)) ||
        "Episódio #{Map.get(episode, :episode_num) || Map.get(episode, :num) || "?"}"

    case Streamix.Gindex.clean_episode_title(raw) do
      "" -> raw
      cleaned -> cleaned
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  def get_image_url(stream_icon, cover) do
    url =
      cond do
        is_binary(stream_icon) and stream_icon != "" -> stream_icon
        is_binary(cover) and cover != "" -> cover
        true -> nil
      end

    # Grid/carousel posters render at ~180px desktop / ~120px mobile, so
    # w342 (via :carousel context) is the sweet spot (~60% less data than w500).
    ImageProxy.browser_poster(url, :carousel)
  end

  def get_display_rating(item) do
    rating = Map.get(item, :rating)

    case rating do
      nil ->
        nil

      %Decimal{} = d ->
        if Decimal.compare(d, Decimal.new("0")) == :gt do
          d |> Decimal.div(2) |> Decimal.round(1) |> Decimal.to_string()
        else
          nil
        end

      n when is_number(n) and n > 0 ->
        Float.round(n / 2, 1) |> to_string()

      _ ->
        nil
    end
  end
end
