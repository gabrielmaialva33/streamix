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

  # Public routes - landing page only
  scope "/", StreamixWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{StreamixWeb.UserAuth, :mount_current_scope}],
      layout: {StreamixWeb.Layouts, :app} do
      live "/", HomeLive, :index
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
      live "/search", SearchLive, :index

      # Global catalog (uses system global provider)
      live "/browse", Content.LiveChannelsLive, :index
      live "/browse/movies", Content.MoviesLive, :index
      live "/browse/movies/:id", Content.MovieDetailLive, :show
      live "/browse/series", Content.SeriesLive, :index
      live "/browse/series/:id", Content.SeriesDetailLive, :show
      live "/browse/series/:series_id/episode/:id", Content.EpisodeDetailLive, :show

      # User's personal providers (settings area)
      live "/providers", Providers.ProviderListLive, :index
      live "/providers/new", Providers.ProviderListLive, :new
      live "/providers/:provider_id", Content.LiveChannelsLive, :show
      live "/providers/:provider_id/edit", Providers.ProviderListLive, :edit

      # VOD content browsing (user's providers)
      live "/providers/:provider_id/movies", Content.MoviesLive, :index
      live "/providers/:provider_id/movies/:id", Content.MovieDetailLive, :show
      live "/providers/:provider_id/series", Content.SeriesLive, :index
      live "/providers/:provider_id/series/:id", Content.SeriesDetailLive, :show

      live "/providers/:provider_id/series/:series_id/episode/:id",
           Content.EpisodeDetailLive,
           :show

      # User content
      live "/favorites", FavoritesLive, :index
      live "/history", HistoryLive, :index
    end

    # Player with fullscreen layout (requires auth)
    live_session :authenticated_player,
      on_mount: [{StreamixWeb.UserAuth, :require_authenticated}],
      layout: {StreamixWeb.Layouts, :player} do
      live "/watch/:type/:id", PlayerLive, :show
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
