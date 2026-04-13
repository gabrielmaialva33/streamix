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

  def episode_title(episode) do
    Map.get(episode, :title) ||
      "Episódio #{Map.get(episode, :episode_num) || Map.get(episode, :num) || "?"}"
  end

  def get_image_url(stream_icon, cover) do
    url =
      cond do
        is_binary(stream_icon) and stream_icon != "" -> stream_icon
        is_binary(cover) and cover != "" -> cover
        true -> nil
      end

    # Use optimized card size for thumbnails (Netflix uses 20-30KB)
    ImageProxy.card(url)
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
