defmodule Streamix.Iptv.Catalog.Serializer do
  @moduledoc """
  Builds the JSON payload maps that the TV/mobile clients consume.

  Pure transformation from catalog structs (`Movie`, `Series`, `Season`,
  `Episode`, `LiveChannel`) into plain maps ready for `Phoenix.Controller.json/2`.
  Side-concerns like stream URL signing and image proxying are delegated
  to `StreamixWeb.Catalog.StreamUrls` and `StreamixWeb.Catalog.ImageProxy`
  — this module only wires them in and shapes the final payload.

  Keeping this under the `Streamix.Iptv` namespace (not `StreamixWeb`)
  reflects that the payload shape is a domain contract with clients, not
  a controller concern.
  """

  alias Streamix.Helpers
  alias Streamix.Iptv.{Movie, Series}
  alias StreamixWeb.Catalog.ImageProxy
  alias StreamixWeb.Catalog.StreamUrls
  alias StreamixWeb.Helpers.ResizeUrl

  # Netflix-style responsive images: hand clients a stable set of
  # pre-sized variants so the TV renderer can pick the right one for
  # the viewport without shipping a CDN wrapper in JS. The raw URLs stay
  # in `poster` / `backdrop` for legacy clients.
  @poster_widths [240, 480, 720]
  @backdrop_widths [720, 1280]

  # ---------------------------------------------------------------------
  # Featured
  # ---------------------------------------------------------------------

  @doc """
  Shapes the featured hero content. Returns `nil` when there's nothing
  to feature so callers can surface it unchanged.
  """
  def serialize_featured({:movie, movie}), do: serialize_featured_movie(movie)
  def serialize_featured({:series, series}), do: serialize_featured_series(series)
  def serialize_featured(nil), do: nil

  defp serialize_featured_movie(movie) do
    poster = ImageProxy.proxy(movie.stream_icon)
    backdrops = Movie.backdrop_urls(movie) || []
    hero_backdrop = List.first(backdrops) || movie.stream_icon

    %{
      id: movie.id,
      type: "movie",
      title: movie.title || movie.name,
      name: movie.name,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      plot: movie.plot,
      poster: poster,
      backdrop: featured_backdrop(backdrops, poster)
    }
    |> with_image_variants(movie.stream_icon, hero_backdrop)
  end

  defp serialize_featured_series(series) do
    poster = ImageProxy.proxy(series.cover)
    backdrops = Series.backdrop_urls(series) || []
    hero_backdrop = List.first(backdrops) || series.cover

    %{
      id: series.id,
      type: "series",
      title: series.title || series.name,
      name: series.name,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      plot: series.plot,
      poster: poster,
      backdrop: featured_backdrop(backdrops, poster)
    }
    |> with_image_variants(series.cover, hero_backdrop)
  end

  # Always returns a non-empty list when a poster exists, so hero rendering
  # never has to deal with null. Callers can prefer index 0 for the hero bg.
  defp featured_backdrop([], nil), do: []
  defp featured_backdrop([], poster), do: [poster]

  defp featured_backdrop(urls, _poster) when is_list(urls) do
    proxied = ImageProxy.proxy(urls)
    if is_list(proxied), do: Enum.reject(proxied, &is_nil/1), else: [proxied]
  end

  defp with_image_variants(payload, poster_url, backdrop_url) do
    payload
    |> Map.merge(ResizeUrl.flatten("poster", poster_url, @poster_widths))
    |> Map.merge(ResizeUrl.flatten("backdrop", backdrop_url, @backdrop_widths))
  end

  # ---------------------------------------------------------------------
  # Movies
  # ---------------------------------------------------------------------

  def serialize_movie(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      poster: ImageProxy.proxy(movie.stream_icon),
      duration: format_duration(movie.duration_secs)
    }
  end

  def serialize_movie_detail(movie) do
    %{
      id: movie.id,
      name: movie.name,
      title: movie.title,
      year: movie.year,
      rating: movie.rating && Decimal.to_float(movie.rating),
      genre: Helpers.genre_names(movie.genres),
      plot: movie.plot,
      cast: Helpers.cast_names(movie.credits),
      director: Helpers.director_names(movie.credits),
      duration: format_duration(movie.duration_secs),
      content_rating: movie.content_rating,
      tagline: movie.tagline,
      poster: ImageProxy.proxy(movie.stream_icon),
      backdrop: ImageProxy.proxy(Movie.backdrop_urls(movie)),
      youtube_trailer: movie.youtube_trailer,
      stream_url: StreamUrls.signed_movie_url(movie),
      browser_stream_url: StreamUrls.browser_movie_url(movie)
    }
    |> with_image_variants(movie.stream_icon, List.first(Movie.backdrop_urls(movie) || []))
  end

  # ---------------------------------------------------------------------
  # Series / Seasons / Episodes
  # ---------------------------------------------------------------------

  def serialize_series(series) do
    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      poster: ImageProxy.proxy(series.cover)
    }
  end

  def serialize_series_detail(series) do
    seasons = series.seasons || []

    %{
      id: series.id,
      name: series.name,
      title: series.title,
      year: series.year,
      rating: series.rating && Decimal.to_float(series.rating),
      genre: Helpers.genre_names(series.genres),
      plot: series.plot,
      cast: Helpers.cast_names(series.credits),
      director: Helpers.director_names(series.credits),
      poster: ImageProxy.proxy(series.cover),
      backdrop: ImageProxy.proxy(Series.backdrop_urls(series)),
      season_count: length(seasons),
      episode_count: Enum.sum(Enum.map(seasons, fn s -> length(s.episodes || []) end)),
      seasons: Enum.map(seasons, &serialize_season/1)
    }
    |> with_image_variants(series.cover, List.first(Series.backdrop_urls(series) || []))
  end

  def serialize_season(season) do
    %{
      id: season.id,
      name: season.name,
      season_number: season.season_number,
      episode_count: length(season.episodes || []),
      episodes: Enum.map(season.episodes || [], &serialize_episode/1)
    }
  end

  def serialize_episode(episode) do
    %{
      id: episode.id,
      title: episode.title,
      episode_num: episode.episode_num,
      plot: episode.plot,
      still: ImageProxy.proxy(episode.still_path),
      duration: format_duration(episode.duration_secs),
      air_date: episode.air_date
    }
  end

  def serialize_episode_detail(episode) do
    series = episode.season.series

    %{
      id: episode.id,
      title: episode.title,
      episode_num: episode.episode_num,
      season_number: episode.season.season_number,
      plot: episode.plot,
      still: ImageProxy.proxy(episode.still_path),
      duration: format_duration(episode.duration_secs),
      air_date: episode.air_date,
      series_id: series.id,
      series_name: series.name,
      stream_url: StreamUrls.signed_episode_url(episode),
      browser_stream_url: StreamUrls.browser_episode_url(episode)
    }
  end

  # ---------------------------------------------------------------------
  # Channels
  # ---------------------------------------------------------------------

  def serialize_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: ImageProxy.proxy(channel.stream_icon)
    }
  end

  def serialize_channel_detail(channel) do
    %{
      id: channel.id,
      name: channel.name,
      icon: ImageProxy.proxy(channel.stream_icon),
      stream_url: StreamUrls.signed_channel_url(channel),
      browser_stream_url: StreamUrls.browser_channel_url(channel)
    }
  end

  # ---------------------------------------------------------------------
  # Ranked / Suggest payloads
  # ---------------------------------------------------------------------

  def serialize_ranked_movie(movie) do
    movie |> serialize_movie() |> Map.put(:score, rank_score(movie))
  end

  def serialize_ranked_series(series) do
    series |> serialize_series() |> Map.put(:score, rank_score(series))
  end

  def serialize_ranked_channel(channel) do
    channel |> serialize_channel() |> Map.put(:score, rank_score(channel))
  end

  def suggest_movie(m) do
    %{
      id: m.id,
      type: "movie",
      title: m.title || m.name,
      year: m.year,
      poster: ImageProxy.proxy(m.stream_icon),
      score: rank_score(m)
    }
  end

  def suggest_series(s) do
    %{
      id: s.id,
      type: "series",
      title: s.title || s.name,
      year: s.year,
      poster: ImageProxy.proxy(s.cover),
      score: rank_score(s)
    }
  end

  def suggest_channel(c) do
    %{
      id: c.id,
      type: "channel",
      title: c.name,
      poster: ImageProxy.proxy(c.stream_icon),
      score: rank_score(c)
    }
  end

  # RankedSearch stitches :rank_score onto the struct as a virtual field
  # via `select_merge`. If for some reason the column isn't populated
  # (e.g. a direct Repo.all bypassing the helper) we fall back to 0 so
  # the API response shape stays stable.
  defp rank_score(%{rank_score: s}) when is_integer(s), do: s
  defp rank_score(_), do: 0

  # ---------------------------------------------------------------------
  # Batch helper
  # ---------------------------------------------------------------------

  def serialize_items("series", items), do: Enum.map(items, &serialize_series/1)
  def serialize_items(_, items), do: Enum.map(items, &serialize_movie/1)

  # ---------------------------------------------------------------------
  # Shared formatting
  # ---------------------------------------------------------------------

  defp format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    mins = rem(total_minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}min"
    end
  end

  defp format_duration(_), do: nil
end
