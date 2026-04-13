defmodule StreamixWeb.ContentComponents do
  @moduledoc """
  Content browsing UI components for Streamix.
  Automatically delegates to sub-modules in `StreamixWeb.Content`.
  """

  defdelegate content_tabs(assigns), to: StreamixWeb.Content.NavigationComponents
  defdelegate browse_tabs(assigns), to: StreamixWeb.Content.NavigationComponents
  defdelegate source_tabs(assigns), to: StreamixWeb.Content.NavigationComponents
  defdelegate section_header(assigns), to: StreamixWeb.Content.NavigationComponents

  defdelegate movie_card(assigns), to: StreamixWeb.Content.CardComponents
  defdelegate series_card(assigns), to: StreamixWeb.Content.CardComponents
  defdelegate episode_card(assigns), to: StreamixWeb.Content.CardComponents

  defdelegate season_accordion(assigns), to: StreamixWeb.Content.DetailComponents
  defdelegate content_detail_modal(assigns), to: StreamixWeb.Content.DetailComponents

  defdelegate content_grid(assigns), to: StreamixWeb.Content.CarouselComponents
  defdelegate content_carousel(assigns), to: StreamixWeb.Content.CarouselComponents
  defdelegate content_hero(assigns), to: StreamixWeb.Content.CarouselComponents
  defdelegate for_you_section(assigns), to: StreamixWeb.Content.CarouselComponents
end
