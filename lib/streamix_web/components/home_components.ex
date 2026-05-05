defmodule StreamixWeb.HomeComponents do
  @moduledoc """
  Public facade for Home and Landing page components.
  """

  defdelegate render_landing_page(assigns), to: StreamixWeb.Home.Landing
  defdelegate landing_features(assigns), to: StreamixWeb.Home.Landing
  defdelegate feature_card(assigns), to: StreamixWeb.Home.Landing
  defdelegate landing_faq(assigns), to: StreamixWeb.Home.Landing
  defdelegate faq_item(assigns), to: StreamixWeb.Home.Landing

  defdelegate render_authenticated_home(assigns), to: StreamixWeb.Home.Authenticated

  defdelegate render_hero_section(assigns), to: StreamixWeb.Home.Hero
  defdelegate hero_background(assigns), to: StreamixWeb.Home.Hero
  defdelegate hero_fallback(assigns), to: StreamixWeb.Home.Hero
  defdelegate hero_content(assigns), to: StreamixWeb.Home.Hero

  defdelegate carousel_arrows(assigns), to: StreamixWeb.Home.Carousel
  defdelegate render_content_carousel(assigns), to: StreamixWeb.Home.Carousel
  defdelegate render_ai_trending_section(assigns), to: StreamixWeb.Home.Carousel
  defdelegate render_ai_series_section(assigns), to: StreamixWeb.Home.Carousel
  defdelegate render_ai_channels_section(assigns), to: StreamixWeb.Home.Carousel
  defdelegate render_top_10(assigns), to: StreamixWeb.Home.Carousel
  defdelegate top_10_card(assigns), to: StreamixWeb.Home.Carousel
  defdelegate see_more_card(assigns), to: StreamixWeb.Home.Carousel

  defdelegate render_movie_card(assigns), to: StreamixWeb.Home.Cards
  defdelegate render_series_card(assigns), to: StreamixWeb.Home.Cards
  defdelegate channel_card(assigns), to: StreamixWeb.Home.Cards
  defdelegate history_item(assigns), to: StreamixWeb.Home.Cards
  defdelegate favorite_item(assigns), to: StreamixWeb.Home.Cards

  defdelegate get_backdrop(content), to: StreamixWeb.Home.Helpers
  defdelegate backdrop_urls(content), to: StreamixWeb.Home.Helpers
  defdelegate content_path(type, content), to: StreamixWeb.Home.Helpers
  defdelegate content_info_path(type, content), to: StreamixWeb.Home.Helpers
  defdelegate watch_path(type, id), to: StreamixWeb.Home.Helpers
  defdelegate content_type_icon(type), to: StreamixWeb.Home.Helpers
  defdelegate format_content_type(type), to: StreamixWeb.Home.Helpers
  defdelegate progress_percent(entry), to: StreamixWeb.Home.Helpers
  defdelegate format_relative_time(datetime), to: StreamixWeb.Home.Helpers
  defdelegate get_see_more_path(type, items), to: StreamixWeb.Home.Helpers
end
