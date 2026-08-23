defmodule StreamixWeb.E2E.HomeSkeletonTest do
  @moduledoc """
  Regression coverage for the progressive home shell and responsive catalog.

  The home previously waited for every catalog and personalization fetch before
  replacing one page-wide skeleton. Slow AI/profile work therefore hid an
  otherwise usable catalog. The current contract renders the shell immediately,
  computes personalization inputs once, and resolves each shelf group
  independently.

      mix test --include playwright test/streamix_web/e2e/home_skeleton_test.exs
  """

  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :webkit
                       end)

  @compact_mobile_opts [
                         viewport: %{width: 360, height: 800},
                         device_scale_factor: 3.0,
                         service_workers: "block"
                       ] ++
                         if(@playwright_browser == :firefox,
                           do: [],
                           else: [is_mobile: true]
                         )

  @mobile_opts [
                 viewport: %{width: 390, height: 844},
                 device_scale_factor: 3.0,
                 service_workers: "block"
               ] ++
                 if(@playwright_browser == :firefox,
                   do: [],
                   else: [is_mobile: true]
                 )

  @large_mobile_opts [
                       viewport: %{width: 430, height: 932},
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

  describe "progressive HomeLive" do
    test "renders its shell immediately and resolves every shelf group", %{conn: conn} do
      conn
      |> login(user_fixture())
      |> visit(~p"/")
      |> assert_has("#home-progressive-shell")
      |> assert_has("#home-premium-cta")
      |> assert_has("#home-progressive-shell[aria-busy='false']", timeout: 10_000)
      |> refute_has(~s|[data-loading-home="true"]|)
    end
  end

  @tag browser_context_opts: @compact_mobile_opts
  test "compact mobile catalog remains dense at 360px", %{conn: conn} do
    assert_mobile_catalog(conn, 360)
  end

  @tag browser_context_opts: @mobile_opts
  test "standard mobile catalog remains dense at 390px", %{conn: conn} do
    assert_mobile_catalog(conn, 390)
  end

  @tag browser_context_opts: @large_mobile_opts
  test "large mobile catalog remains dense at 430px", %{conn: conn} do
    assert_mobile_catalog(conn, 430)
  end

  defp assert_mobile_catalog(conn, viewport_width) do
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
    |> assert_compact_poster_grid(viewport_width)
    |> visit(~p"/providers/#{provider.id}")
    |> assert_has("body .phx-connected #channels .catalog-stream-item")
    |> assert_compact_live_grid(viewport_width)
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

  defp assert_compact_poster_grid(session, viewport_width) do
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
        assert state["viewportWidth"] == viewport_width
        assert length(state["rects"]) == 6

        [first, second, third, fourth | _rest] = state["rects"]
        assert_in_delta first["top"], second["top"], 2
        assert_in_delta first["top"], third["top"], 2
        assert fourth["top"] > first["bottom"]

        expected_width = (viewport_width - 52) / 3

        for rect <- Enum.take(state["rects"], 3) do
          assert_in_delta rect["width"], expected_width, 6
          assert rect["height"] > rect["width"] * 1.6
          assert rect["right"] <= viewport_width
        end

        assert state["favorite"]["width"] >= 44
        assert state["favorite"]["height"] >= 44
        assert state["favorite"]["right"] <= 390
        assert state["toolbarHeight"] <= 130
        assert state["horizontalOverflow"] <= 1
      end
    )
  end

  defp assert_compact_live_grid(session, viewport_width) do
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

        expected_width = (viewport_width - 42) / 2

        for rect <- Enum.take(state["rects"], 2) do
          assert_in_delta rect["width"], expected_width, 7
          assert rect["height"] <= 180
          assert rect["right"] <= viewport_width
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
