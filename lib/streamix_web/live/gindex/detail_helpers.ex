defmodule StreamixWeb.Gindex.DetailHelpers do
  @moduledoc """
  Pure helpers shared by the gindex movie/series/anime detail
  LiveViews. No `Phoenix.LiveView` or `Phoenix.Component` macros here —
  keep this module trivially testable.

  The xtream detail LiveViews (`StreamixWeb.Content.*`) have their own
  helper zoo (format_duration, content_rating_class, trailer/credits
  parsing). Those are a candidate for a future pass once the gindex
  shape stabilizes; for now only the gindex helpers live here.

  Callers pass the entity struct. This module never dispatches on a
  specific schema — it reads generic `:title` and `:name` fields via
  `Map.get/2`.
  """

  alias Streamix.Gindex.DisplayName

  @doc """
  Display title for series and animes.

  Release noise leaks into `entity.name` when the folder wasn't curated.
  Prefer the enriched `title` when it exists **and differs from the raw
  name**; otherwise run the raw value through the parser so the header
  stays clean.

  Used by `SeriesDetailLive` and `AnimeDetailLive`.
  """
  def display_title(entity) do
    title = Map.get(entity, :title)
    name = Map.get(entity, :name)

    if is_binary(title) and String.trim(title) != "" and title != name do
      title
    else
      DisplayName.clean_title(name)
    end
  end

  @doc """
  Display title for movies — trusts the enriched `title` even when it
  matches `name`, because the movie enrichment pass sets `title` to the
  canonical value directly. Falls back to the cleaned raw name.

  Used by `MovieDetailLive`.
  """
  def display_title_movie(entity) do
    title = Map.get(entity, :title)

    if is_binary(title) and String.trim(title) != "" do
      title
    else
      DisplayName.clean_title(Map.get(entity, :name))
    end
  end

  @doc """
  Episode display title. Falls back to `"Episódio <num>"` when the raw
  episode has neither `:title` nor `:name`, and runs whatever value we
  do have through `DisplayName.clean_episode/1`. If the parser strips
  everything, we keep the raw value so the row is never blank.

  Used by `SeriesDetailLive` and `AnimeDetailLive`.
  """
  def episode_title(episode) do
    raw =
      Map.get(episode, :title) ||
        Map.get(episode, :name) ||
        "Episódio #{Map.get(episode, :episode_num)}"

    cleaned = DisplayName.clean_episode(raw)
    if cleaned == "", do: raw, else: cleaned
  end
end
