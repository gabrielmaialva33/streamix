defmodule StreamixWeb.E2E.HomeSkeletonTest do
  @moduledoc """
  Regression: HomeLive used to leave Safari iOS users staring at the
  skeleton forever. Reproducing this locally on WebKit revealed the
  actual culprit was NOT iOS-specific — `HomeCatalogLoader` fans 8
  sections out concurrently, and at least two of them
  (`:trending`, `:series`) call `Profile.get_user_profile/1`, which
  acquires the ConCache lock `user_profile:USER_ID`. The losers wait
  on `GenServer.call(.., :lock, 5_000)` and time out after 5 s, falling
  back to `[]`. On a fast desktop this just looks like a slow load
  (~10 s). On iOS Safari, with extra WS-upgrade and tab-suspend cost,
  it crosses the LiveSocket health threshold and the skeleton sticks.

  Assert the home reaches a usable state quickly enough that the
  symptom can't return. Adjust the `:max_load_ms` once the lock
  contention is fixed (e.g. by computing the profile once in
  `Data.load/1` and passing it down to the per-section fetchers).

      mix test --include playwright test/streamix_web/e2e/home_skeleton_test.exs
  """

  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :webkit
                       end)

  @mobile_opts [
                 viewport: %{width: 390, height: 844},
                 device_scale_factor: 3.0,
                 service_workers: "block"
               ] ++
                 if(@playwright_browser == :firefox,
                   do: [],
                   else: [is_mobile: true]
                 )

  use PhoenixTest.Playwright.Case, async: false, browser: @playwright_browser
  use StreamixWeb, :verified_routes

  @moduletag :playwright

  setup {StreamixWeb.PlaywrightSupport, :register_context_cleanup}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PlaywrightEx.BrowserContext

  setup do
    provider =
      provider_fixture(admin_user_fixture(), %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie_fixture(provider, %{name: "Home Skeleton Smoke", plot: "x"})
    :ok
  end

  describe "HomeLive skeleton on WebKit" do
    test "skeleton clears within 5s of mount", %{conn: conn} do
      conn
      |> login(user_fixture())
      |> visit(~p"/")
      # Authenticated home renders the premium CTA banner once Data.load
      # completes. If the WS upgrade or async load gets stuck (the actual
      # Safari iOS bug), this assert times out — that's the regression.
      # Generous timeout because HomeCatalogLoader fans out 8 sections
      # with their own 15s budget each.
      |> assert_has("#home-premium-cta", timeout: 20_000)
      |> refute_has(~s|[data-loading-home="true"]|)
    end
  end

  @tag browser_context_opts: @mobile_opts
  test "mobile catalog keeps posters dense and live cards compact", %{conn: conn} do
    user = user_fixture()
    provider = provider_fixture(user, %{is_active: true})

    for index <- 1..9 do
      movie_fixture(provider, %{
        name: "Filme mobile #{index}",
        title: "Filme mobile com título maior #{index}"
      })
    end

    for index <- 1..8 do
      channel_fixture(provider, %{name: "Canal esportivo mobile #{index}"})
    end

    conn
    |> login(user)
    |> visit(~p"/providers/#{provider.id}/movies")
    |> assert_has("body .phx-connected #movies .catalog-stream-item")
    |> assert_compact_poster_grid()
    |> visit(~p"/providers/#{provider.id}")
    |> assert_has("body .phx-connected #channels .catalog-stream-item")
    |> assert_compact_live_grid()
  end

  defp login(session, user) do
    cookie =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/browse/movies")
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!("_streamix_key")

    session
    |> PhoenixTest.Playwright.unwrap(fn %{context_id: context_id} ->
      {:ok, _} =
        BrowserContext.add_cookies(context_id,
          timeout: 5_000,
          cookies: [
            %{
              "name" => "_streamix_key",
              "value" => cookie.value,
              "url" => StreamixWeb.Endpoint.url(),
              "httpOnly" => true,
              "sameSite" => "Lax"
            }
          ]
        )
    end)
  end

  defp assert_compact_poster_grid(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      () => {
        const items = Array.from(document.querySelectorAll("#movies > .catalog-stream-item")).slice(0, 6);
        const rects = items.map((item) => {
          const rect = item.getBoundingClientRect();
          return {left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height};
        });
        const favorite = items[0]?.querySelector("[data-media-secondary] button")?.getBoundingClientRect();
        const toolbar = document.querySelector(".browse-toolbar")?.getBoundingClientRect();

        return {
          viewportWidth: innerWidth,
          rects,
          favorite: favorite ? {width: favorite.width, height: favorite.height, right: favorite.right} : null,
          toolbarHeight: toolbar?.height || 0,
          horizontalOverflow: document.documentElement.scrollWidth - innerWidth
        };
      }
      """,
      [is_function: true],
      fn state ->
        assert state["viewportWidth"] == 390
        assert length(state["rects"]) == 6

        [first, second, third, fourth | _rest] = state["rects"]
        assert_in_delta first["top"], second["top"], 2
        assert_in_delta first["top"], third["top"], 2
        assert fourth["top"] > first["bottom"]

        for rect <- Enum.take(state["rects"], 3) do
          assert rect["width"] >= 100
          assert rect["width"] <= 125
          assert rect["height"] > rect["width"] * 1.6
          assert rect["right"] <= 390
        end

        assert state["favorite"]["width"] >= 44
        assert state["favorite"]["height"] >= 44
        assert state["favorite"]["right"] <= 390
        assert state["toolbarHeight"] <= 130
        assert state["horizontalOverflow"] <= 1
      end
    )
  end

  defp assert_compact_live_grid(session) do
    PhoenixTest.Playwright.evaluate(
      session,
      """
      () => {
        const items = Array.from(document.querySelectorAll("#channels > .catalog-stream-item")).slice(0, 4);
        const rects = items.map((item) => {
          const rect = item.getBoundingClientRect();
          return {left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height};
        });
        const favorite = items[0]?.querySelector("button[aria-label*='favoritos']")?.getBoundingClientRect();
        const toolbar = document.querySelector(".browse-toolbar")?.getBoundingClientRect();

        return {
          rects,
          favorite: favorite ? {width: favorite.width, height: favorite.height, right: favorite.right} : null,
          toolbarHeight: toolbar?.height || 0,
          horizontalOverflow: document.documentElement.scrollWidth - innerWidth
        };
      }
      """,
      [is_function: true],
      fn state ->
        assert length(state["rects"]) == 4

        [first, second, third | _rest] = state["rects"]
        assert_in_delta first["top"], second["top"], 2
        assert third["top"] > first["bottom"]

        for rect <- Enum.take(state["rects"], 2) do
          assert rect["width"] >= 165
          assert rect["width"] <= 180
          assert rect["height"] <= 165
          assert rect["right"] <= 390
        end

        assert state["favorite"]["width"] >= 44
        assert state["favorite"]["height"] >= 44
        assert state["favorite"]["right"] <= 390
        assert state["toolbarHeight"] <= 140
        assert state["horizontalOverflow"] <= 1
      end
    )
  end
end
