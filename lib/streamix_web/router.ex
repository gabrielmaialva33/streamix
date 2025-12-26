defmodule StreamixWeb.Router do
  use StreamixWeb, :router

  import StreamixWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StreamixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Stream proxy - public access for video streaming
  scope "/api", StreamixWeb do
    pipe_through :api

    get "/stream/proxy", StreamController, :proxy
  end

  # Public routes - no auth required
  scope "/", StreamixWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{StreamixWeb.UserAuth, :mount_current_scope}],
      layout: {StreamixWeb.Layouts, :app} do
      live "/", HomeLive, :index
      live "/search", SearchLive, :index

      # Public content browsing (for global/public providers)
      live "/providers/:provider_id/series/:id", Content.SeriesDetailLive, :show
    end

    # Player with fullscreen layout (public access for global/public content)
    live_session :public_player,
      on_mount: [{StreamixWeb.UserAuth, :mount_current_scope}],
      layout: {StreamixWeb.Layouts, :player} do
      live "/watch/:type/:id", PlayerLive, :show
    end
  end

  # Guest-only routes (redirect if logged in)
  scope "/", StreamixWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :guest,
      on_mount: [{StreamixWeb.UserAuth, :redirect_if_authenticated}],
      layout: {StreamixWeb.Layouts, :app} do
      live "/login", User.LoginLive, :new
      live "/register", User.RegisterLive, :new
    end

    post "/login", UserSessionController, :create
  end

  # Authenticated routes
  scope "/", StreamixWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [{StreamixWeb.UserAuth, :require_authenticated}],
      layout: {StreamixWeb.Layouts, :app} do
      live "/settings", User.SettingsLive, :index

      # Provider management
      live "/providers", Providers.ProviderListLive, :index
      live "/providers/new", Providers.ProviderListLive, :new
      live "/providers/:id", Providers.ProviderShowLive, :show
      live "/providers/:id/edit", Providers.ProviderListLive, :edit

      # VOD content browsing (provider-specific, requires auth)
      live "/providers/:provider_id/movies", Content.MoviesLive, :index
      live "/providers/:provider_id/series", Content.SeriesLive, :index

      # User content
      live "/favorites", FavoritesLive, :index
      live "/history", HistoryLive, :index
    end

    delete "/logout", UserSessionController, :delete
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
