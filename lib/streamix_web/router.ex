defmodule StreamixWeb.Router do
  use StreamixWeb, :router

  import StreamixWeb.UserAuth

  # E2E tests with Playwright need the sandbox hook to run *before* UserAuth,
  # which does DB queries. In prod this resolves to `[]`.
  @sandbox_on_mount if Application.compile_env(:streamix, :sql_sandbox),
                      do: [StreamixWeb.LiveAcceptance],
                      else: []

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StreamixWeb.Layouts, :root}
    plug :protect_from_forgery

    # Security headers (CSP is handled by CSPNonce plug)
    plug :put_secure_browser_headers, %{
      "x-frame-options" => "SAMEORIGIN",
      "x-content-type-options" => "nosniff",
      "x-permitted-cross-domain-policies" => "none",
      "referrer-policy" => "strict-origin-when-cross-origin"
    }

    # Dynamic CSP with nonces for script security
    plug StreamixWeb.Plugs.CSPNonce

    plug :fetch_current_scope_for_user
    plug :put_early_hints
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug StreamixWeb.Plugs.CORS
  end

  # Prometheus metrics scrape pipeline — plain text, no JSON/HTML parsing.
  pipeline :metrics do
    plug :accepts, ["text"]
    plug StreamixWeb.Plugs.MetricsAuth
  end

  # Rate-limited API pipeline for sensitive endpoints
  pipeline :api_rate_limited do
    plug :accepts, ["json"]
    plug StreamixWeb.Plugs.CORS
    # 60 requests per minute per IP for stream proxy
    plug StreamixWeb.Plugs.RateLimit, limit: 60, period: 60_000
  end

  # Strict rate limiting for password-handling auth endpoints. Kept
  # tight to blunt credential-stuffing: five attempts per minute per IP
  # is enough for a human who mistyped and far too few for a bot.
  pipeline :auth_rate_limited do
    plug StreamixWeb.Plugs.RateLimit, limit: 5, period: 60_000
  end

  # Looser pipeline for token-lookup endpoints (`/auth/me`, `/auth/logout`).
  # These don't process credentials — they only inspect the caller's
  # existing Bearer token — so they were being unfairly penalised by
  # the login bucket (5/min tripped on hot reloads and screens that
  # re-mount more than once a minute). 60/min gives clients room to
  # refresh aggressively without opening a brute-force window.
  pipeline :auth_session_rate_limited do
    plug StreamixWeb.Plugs.RateLimit, limit: 60, period: 60_000
  end

  # Protected API pipeline with rate limiting and API key auth
  pipeline :api_v1 do
    plug :accepts, ["json"]
    plug StreamixWeb.Plugs.CORS
    # 120 requests per minute per IP
    plug StreamixWeb.Plugs.RateLimit, limit: 120, period: 60_000
    plug StreamixWeb.Plugs.ApiKeyAuth
  end

  # Health check endpoint
  scope "/api", StreamixWeb do
    pipe_through :api

    get "/health", HealthController, :index
    post "/billing/webhooks/stripe", BillingWebhookController, :stripe

    # Client-side diagnostic beacon. Fired by app.js when the home
    # skeleton stays visible >8s — gives us UA + transport + display
    # mode to triage the Safari iOS stuck-skeleton bug. No auth: the
    # beacon comes from sendBeacon() which can't set custom headers.
    post "/internal/home-stuck", InternalDiagController, :home_stuck
  end

  # Authenticated stream proxy for torrent-backed content. The
  # rqbit sidecar URL is internal — this controller is the only way a
  # browser is allowed to reach it, and `:require_authenticated_user`
  # gates that surface.
  scope "/api", StreamixWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/stream/torrent/:info_hash/status", TorrentStreamController, :status
    get "/stream/torrent/:info_hash", TorrentStreamController, :stream
    get "/stream/torrent/:info_hash/:file_idx", TorrentStreamController, :stream
  end

  # Stream proxy - public access for video streaming (rate limited)
  scope "/api", StreamixWeb do
    pipe_through :api_rate_limited

    # Handle CORS preflight for AVPlayer fetch()
    options "/stream/proxy", StreamController, :options
    get "/stream/proxy", StreamController, :proxy
    head "/stream/proxy", StreamController, :proxy

    # Resolve-only endpoint — used by the gindex.mahina.cloud nginx
    # reverse proxy to translate a signed token into the upstream
    # `download.aspx` URL without ever streaming bytes through the
    # BEAM. Authenticated by the X-Internal-Auth header
    # (:gindex_resolve_secret), so the public rate-limited pipeline
    # is fine — unauthenticated callers get a 401 and never see a
    # resolution.
    get "/stream/resolve", StreamController, :resolve

    # GIndex track enumeration. Server-side ffprobe cache replaces the
    # client-side "spawn a 2nd AVPlayer to enumerate" hack. Anonymous,
    # rate-limited — payload is purely informational (track index +
    # language + codec name). Choki content uses hls.js for runtime
    # enumeration and never hits this.
    get "/gindex-tracks/:type/:id", Api.V1.GindexTracksController, :show
  end

  # Credential-handling routes: tight bucket to discourage brute-force.
  scope "/api/v1/auth", StreamixWeb.Api.V1 do
    pipe_through [:api, :auth_rate_limited]

    post "/register", AuthController, :register
    post "/login", AuthController, :login
  end

  # Token-lookup routes: loose bucket so client re-mounts, hot reloads
  # and multi-screen flows don't get throttled on their own session
  # checks.
  scope "/api/v1/auth", StreamixWeb.Api.V1 do
    pipe_through [:api, :auth_session_rate_limited]

    post "/logout", AuthController, :logout
    get "/me", AuthController, :me
  end

  # Protected catalog API for TV app and other clients
  scope "/api/v1", StreamixWeb.Api.V1 do
    pipe_through :api_v1

    # Handle CORS preflight requests
    options "/catalog/*path", CatalogController, :options

    get "/catalog/featured", CatalogController, :featured
    # One-shot home aggregator: featured + trending + recent + top-rated
    # for both movies and series, computed concurrently. Collapses the
    # TV app's cold-start fan-out of five parallel requests into one
    # round trip.
    get "/catalog/home", CatalogController, :home
    get "/catalog/trending", CatalogController, :trending
    get "/catalog/recent", CatalogController, :recent
    get "/catalog/top-rated", CatalogController, :top_rated
    get "/catalog/movies", CatalogController, :movies
    get "/catalog/movies/:id", CatalogController, :show_movie
    get "/catalog/series", CatalogController, :series
    get "/catalog/series/:id", CatalogController, :show_series
    get "/catalog/series/:series_id/episodes/:id", CatalogController, :show_episode
    get "/catalog/episodes/:id", CatalogController, :show_episode
    get "/catalog/channels", CatalogController, :channels
    get "/catalog/channels/:id", CatalogController, :show_channel
    get "/catalog/categories", CatalogController, :categories
    get "/catalog/search", CatalogController, :search
    # Autocomplete/typeahead endpoint. Cheaper payload than /search,
    # tuned for per-keystroke calls from a TV remote.
    get "/catalog/suggest", CatalogController, :suggest

    # Provider health surface — TV clients use this to render a
    # "upstream offline" banner without confusing it with session
    # errors.
    get "/providers/status", StatusController, :index

    # Image proxy+resize for TV/mobile clients — replaces wsrv.nl.
    get "/catalog/images/resize", ImageResizeController, :resize

    # Stream URLs for TV app
    get "/catalog/movies/:id/stream", CatalogController, :movie_stream
    get "/catalog/episodes/:id/stream", CatalogController, :episode_stream
    get "/catalog/channels/:id/stream", CatalogController, :channel_stream

    # Semantic search API
    options "/search/*path", SearchController, :options
    get "/search/movies", SearchController, :movies
    get "/search/series", SearchController, :series
    get "/search/similar/:collection/:id", SearchController, :similar
    get "/search/status", SearchController, :status
    get "/search/info", SearchController, :info

    # Recommendations API
    scope "/recommendations" do
      get "/", RecommendationsController, :index
      get "/similar/:id", RecommendationsController, :similar
      get "/channels", RecommendationsController, :channels
      get "/insights", RecommendationsController, :insights
      post "/refresh", RecommendationsController, :refresh
    end

    # Favorites API (Bearer token auth in controller)
    get "/favorites", FavoritesController, :index
    post "/favorites", FavoritesController, :create
    post "/favorites/toggle", FavoritesController, :toggle
    post "/favorites/sync", FavoritesController, :sync
    delete "/favorites/:type/:content_id", FavoritesController, :delete

    # Watch History API (Bearer token auth in controller)
    get "/history", HistoryController, :index
    post "/history", HistoryController, :upsert
    delete "/history/:id", HistoryController, :delete

    # EPG API
    get "/epg/programs", EpgController, :programs
    get "/epg/now", EpgController, :now

    # Telemetry API (Bearer token auth in controller)
    post "/telemetry/playback", TelemetryController, :ingest

    # Providers API (Bearer token auth in controller)
    get "/providers", ProvidersController, :index
    post "/providers", ProvidersController, :create
    delete "/providers/:id", ProvidersController, :delete
    post "/providers/:id/sync", ProvidersController, :sync
  end

  # Service worker — served from a controller (instead of Plug.Static)
  # so the response carries a per-release `CACHE_VERSION` token. The
  # browser's SW update protocol only fires when the registered
  # script differs byte-by-byte from the on-disk one, so this is what
  # un-pins users from a stale cache after a deploy.
  scope "/", StreamixWeb do
    get "/sw.js", ServiceWorkerController, :show
  end

  # Public routes - landing page only
  scope "/", StreamixWeb do
    pipe_through :browser

    get "/tv/apk", TvDownloadController, :apk
    get "/tv/wgt", TvDownloadController, :wgt

    live_session :public,
      on_mount:
        @sandbox_on_mount ++
          [
            {StreamixWeb.UserAuth, :mount_current_scope},
            StreamixWeb.OnMount.ProviderHealth
          ],
      layout: {StreamixWeb.Layouts, :app} do
      live "/", HomeLive, :index
      live "/plans", PlansLive, :index
      live "/tv", TvLive, :index
    end
  end

  # Guest-only routes (redirect if logged in)
  scope "/", StreamixWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :guest,
      on_mount: @sandbox_on_mount ++ [{StreamixWeb.UserAuth, :redirect_if_authenticated}],
      layout: {StreamixWeb.Layouts, :auth} do
      live "/login", User.LoginLive, :new
      live "/register", User.RegisterLive, :new
    end
  end

  # Rate-limited login endpoint (separate scope for pipeline)
  scope "/", StreamixWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated, :auth_rate_limited]

    post "/login", UserSessionController, :create
  end

  # Authenticated routes
  scope "/", StreamixWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount:
        @sandbox_on_mount ++
          [
            {StreamixWeb.UserAuth, :require_authenticated},
            StreamixWeb.OnMount.ProviderHealth
          ],
      layout: {StreamixWeb.Layouts, :app} do
      live "/settings", User.SettingsLive, :index
      live "/billing", BillingLive, :index
      live "/search", SearchLive, :index

      # Global catalog (uses system global provider)
      live "/browse", Content.LiveChannelsLive, :index
      live "/browse/movies", Content.MoviesLive, :index
      live "/browse/movies/:id", Content.MovieDetailLive, :show
      live "/browse/series", Content.SeriesLive, :index
      live "/browse/series/:id", Content.SeriesDetailLive, :show
      live "/browse/series/:series_id/episode/:id", Content.EpisodeDetailLive, :show
      live "/browse/animes", Gindex.AnimeLive, :index

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

      # GIndex content (GDrive)
      live "/gindex/movies", Gindex.MoviesLive, :index
      live "/gindex/movies/:id", Gindex.MovieDetailLive, :show
      live "/gindex/series/:id", Gindex.SeriesDetailLive, :show
      live "/gindex/animes/:id", Gindex.AnimeDetailLive, :show

      # Watch Party
      live "/party", WatchPartyLive.Index, :index
      live "/party/new/:type/:id", WatchPartyLive.New, :new
      live "/party/:invite_code", WatchPartyLive.Join, :join
    end

    # Player with fullscreen layout (requires auth)
    live_session :authenticated_player,
      on_mount: @sandbox_on_mount ++ [{StreamixWeb.UserAuth, :require_authenticated}],
      layout: {StreamixWeb.Layouts, :player} do
      live "/watch/:type/:id", PlayerLive, :show
      live "/party/:invite_code/watch", WatchPartyLive.Show, :show
    end

    # Admin panel (requires admin role)
    live_session :admin,
      on_mount:
        @sandbox_on_mount ++
          [
            {StreamixWeb.UserAuth, :require_authenticated},
            {StreamixWeb.UserAuth, :require_admin}
          ],
      layout: {StreamixWeb.Layouts, :app} do
      live "/admin", Admin.DashboardLive, :index
      live "/admin/plans", Admin.PlansLive, :index
      live "/admin/plans/new", Admin.PlanFormLive, :new
      live "/admin/plans/:id", Admin.PlanFormLive, :edit
      live "/admin/billing", Admin.BillingLive, :index
      live "/admin/users", Admin.UsersLive, :index
      live "/admin/users/:id", Admin.UserEditLive, :edit
      live "/debug/pwa", Admin.PwaDebugLive, :index
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

  # Prometheus metrics scrape endpoint — protected by basic auth via
  # METRICS_USER / METRICS_PASSWORD env (or :metrics_auth config).
  scope "/", StreamixWeb do
    pipe_through :metrics
    get "/metrics", MetricsController, :scrape
  end

  # Emits an HTTP 103 Early Hints informational response with a
  # `Link: <source.mahina.cloud>; rel=preconnect` header so the browser
  # opens the TCP+TLS connection to the stream proxy *while* Phoenix is
  # still busy mounting the LiveView (DB queries, history record,
  # prewarm task). For navigation requests with adapters that support
  # 103 (Bandit on HTTP/1.1+, HTTP/2, HTTP/3), this shaves a full RTT
  # off the player's first byte. The same Link is repeated as a regular
  # response header for browsers that ignore informational responses.
  defp put_early_hints(conn, _opts) do
    proxy = Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")
    link = "<#{proxy}>; rel=preconnect; crossorigin"

    # Best-effort: a noop on adapters that don't implement inform/3.
    try do
      Plug.Conn.inform(conn, 103, [{"link", link}])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    Plug.Conn.put_resp_header(conn, "link", link)
  end
end
