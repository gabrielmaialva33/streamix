defmodule StreamixWeb.Router do
  use StreamixWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StreamixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StreamixWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/channels", ChannelsLive, :index
    live "/channels/:id", PlayerLive, :show
    live "/favorites", FavoritesLive, :index
    live "/history", HistoryLive, :index
    live "/providers", ProvidersLive, :index
    live "/providers/new", ProvidersLive, :new
    live "/providers/:id/edit", ProvidersLive, :edit
    live "/settings", SettingsLive, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:streamix, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: StreamixWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
