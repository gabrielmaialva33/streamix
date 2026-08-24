defmodule StreamixWeb.Home.Helpers do
  @moduledoc false

  use StreamixWeb, :verified_routes
  alias StreamixWeb.Helpers.ImageProxy

  def get_backdrop(content) do
    case backdrop_urls(content) do
      [first | _] ->
        ImageProxy.browser_poster(first, :hero)

      _ ->
        cover = Map.get(content, :cover) || Map.get(content, :stream_icon)
        ImageProxy.browser_poster(cover, :hero)
    end
  end

  def backdrop_urls(content), do: Streamix.Catalog.backdrop_urls(content)

  def content_path(:movie, movie), do: ~p"/watch/movie/#{movie.id}"
  def content_path(:series, series), do: ~p"/browse/series/#{series.id}"

  def content_info_path(:movie, movie), do: ~p"/browse/movies/#{movie.id}"
  def content_info_path(:series, series), do: ~p"/browse/series/#{series.id}"

  def watch_path("live_channel", id), do: ~p"/watch/live_channel/#{id}"
  def watch_path("live", id), do: ~p"/watch/live_channel/#{id}"
  def watch_path("movie", id), do: ~p"/watch/movie/#{id}"
  def watch_path("episode", id), do: ~p"/watch/episode/#{id}"
  def watch_path(_, id), do: ~p"/watch/movie/#{id}"

  def content_type_icon("live"), do: "hero-tv"
  def content_type_icon("movie"), do: "hero-film"
  def content_type_icon("series"), do: "hero-video-camera"
  def content_type_icon("episode"), do: "hero-play"
  def content_type_icon(_), do: "hero-film"

  def format_content_type("live"), do: "TV"
  def format_content_type("movie"), do: "Filme"
  def format_content_type("series"), do: "Série"
  def format_content_type("episode"), do: "Episódio"
  def format_content_type(_), do: "Vídeo"

  def progress_percent(%{progress_seconds: progress, duration_seconds: duration})
      when is_number(progress) and is_number(duration) and duration > 0 do
    min(round(progress / duration * 100), 100)
  end

  def progress_percent(_), do: 0

  def format_relative_time(nil), do: ""

  def format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora"
      diff < 3600 -> "há #{div(diff, 60)} min"
      diff < 86_400 -> "há #{div(diff, 3600)} h"
      diff < 604_800 -> "há #{div(diff, 86_400)} dias"
      true -> Calendar.strftime(datetime, "%d/%m")
    end
  end

  def build_carousel_id(type, title) do
    base = "carousel-#{type}"

    case title do
      nil -> base
      "" -> base
      title when is_binary(title) -> base <> "-" <> slugify(title)
      other -> base <> "-" <> slugify(to_string(other))
    end
  end

  def get_see_more_path(:movies, _), do: ~p"/browse/movies"
  def get_see_more_path(:series, _), do: ~p"/browse/series"
  def get_see_more_path(:channels, _), do: ~p"/browse"
  def get_see_more_path(:history, _), do: ~p"/history"
  def get_see_more_path(:favorites, _), do: ~p"/favorites"
  def get_see_more_path(_, _), do: nil

  defp slugify(str) do
    str
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
