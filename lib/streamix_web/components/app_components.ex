defmodule StreamixWeb.AppComponents do
  @moduledoc """
  Public facade for application-specific UI components.
  """

  defdelegate theme_toggle(assigns), to: StreamixWeb.App.Navigation
  defdelegate sidebar(assigns), to: StreamixWeb.App.Navigation
  defdelegate nav_link(assigns), to: StreamixWeb.App.Navigation
  defdelegate bottom_tab(assigns), to: StreamixWeb.App.Navigation
  defdelegate dropdown_item(assigns), to: StreamixWeb.App.Navigation

  defdelegate premium_badge(assigns), to: StreamixWeb.AppComponents.Premium
  defdelegate plan_access_badge(assigns), to: StreamixWeb.AppComponents.Premium
  defdelegate premium_cta_banner(assigns), to: StreamixWeb.AppComponents.Premium

  defdelegate live_channel_card(assigns), to: StreamixWeb.App.Media
  defdelegate provider_card(assigns), to: StreamixWeb.App.Media
  defdelegate video_player_v2(assigns), to: StreamixWeb.App.Media

  defdelegate category_filter_v2(assigns), to: StreamixWeb.App.Filters
  defdelegate provider_filter(assigns), to: StreamixWeb.App.Filters
  defdelegate search_input(assigns), to: StreamixWeb.App.Filters

  defdelegate empty_state(assigns), to: StreamixWeb.App.Feedback
  defdelegate loading_spinner(assigns), to: StreamixWeb.App.Feedback
  defdelegate history_card_v2(assigns), to: StreamixWeb.App.Feedback
  defdelegate favorite_card(assigns), to: StreamixWeb.App.Feedback
end
