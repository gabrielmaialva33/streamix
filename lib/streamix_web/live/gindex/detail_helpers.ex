defmodule StreamixWeb.Gindex.DetailHelpers do
  @moduledoc """
  Pure helpers shared by the gindex movie/series/anime detail
  LiveViews. No `Phoenix.LiveView` or `Phoenix.Component` macros here —
  keep this module trivially testable.
  """

  alias Streamix.Gindex
  alias StreamixWeb.Content.DetailComponents
  alias StreamixWeb.Content.DisplayTitle

  @doc """
  Display title for series and animes, cleaned of release noise.
  """
  def display_title(entity) do
    title = Map.get(entity, :title)
    name = Map.get(entity, :name)

    raw =
      if is_binary(title) and String.trim(title) != "" and title != name do
        title
      else
        Gindex.clean_display_title(name)
      end

    DisplayTitle.title(raw)
  end

  @doc """
  Display title for movies, cleaned of release noise.
  """
  def display_title_movie(entity) do
    title = Map.get(entity, :title)

    raw =
      if is_binary(title) and String.trim(title) != "" do
        title
      else
        Gindex.clean_display_title(Map.get(entity, :name))
      end

    DisplayTitle.title(raw)
  end

  @doc """
  Episode display title via `DetailComponents.episode_item_title/2`.
  """
  def episode_title(episode, season_number \\ nil) do
    DetailComponents.episode_item_title(episode, season_number)
  end
end
