defmodule StreamixWeb.E2E.WebKitReconnectTest do
  @moduledoc """
  Validates LiveView reconnect behaviour under Safari iOS-style tab
  suspension, using Playwright's WebKit build (closest simulation of
  Mobile Safari without a real iPhone).

  Each scenario dispatches the suspend/resume events the `app.js`
  listeners react to and asserts the LiveSocket comes back connected.
  Excluded by default — run with:

      mix test --include playwright test/streamix_web/e2e/webkit_reconnect_test.exs
  """

  # Default to webkit (this suite targets Safari iOS behaviour), but let the
  # CI matrix override it via PLAYWRIGHT_BROWSER=chromium|firefox|webkit.
  @playwright_browser (case System.get_env("PLAYWRIGHT_BROWSER") do
                         "chromium" -> :chromium
                         "firefox" -> :firefox
                         "webkit" -> :webkit
                         _ -> :webkit
                       end)

  use PhoenixTest.Playwright.Case, async: false, browser: @playwright_browser
  use StreamixWeb, :verified_routes

  @moduletag :playwright

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  setup do
    provider =
      provider_fixture(admin_user_fixture(), %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    movie_fixture(provider, %{name: "Reconnect Smoke", plot: "x"})
    :ok
  end

  describe "LiveView reconnect on WebKit" do
    test "reconnects after visibilitychange hidden→visible", %{conn: conn} do
      conn
      |> login(user_fixture())
      |> assert_connected()
      |> run_js("""
      Object.defineProperty(document, 'visibilityState', {value: 'hidden', configurable: true});
      document.dispatchEvent(new Event('visibilitychange'));
      Object.defineProperty(document, 'visibilityState', {value: 'visible', configurable: true});
      document.dispatchEvent(new Event('visibilitychange'));
      """)
      |> assert_connected()
    end

    test "reconnects after simulated bfcache pageshow", %{conn: conn} do
      conn
      |> login(user_fixture())
      |> assert_connected()
      |> run_js("""
      window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted: true}));
      """)
      |> assert_connected()
    end

    test "reconnects after offline→online cycle", %{conn: conn} do
      conn
      |> login(user_fixture())
      |> assert_connected()
      |> run_js("""
      window.dispatchEvent(new Event('offline'));
      window.dispatchEvent(new Event('online'));
      """)
      |> assert_connected()
    end
  end

  defp login(conn, user) do
    conn
    |> visit(~p"/browse/movies")
    |> assert_has("body .phx-connected form[action='/login']")
    |> fill_in("Email", with: user.email)
    |> fill_in("Senha", with: valid_user_password())
    |> submit()
    |> assert_has("#movies")
  end

  # Wait for LiveView to be connected via the `.phx-connected` DOM class.
  # More reliable than `window.liveSocket.isConnected()` because a reconnect
  # may trigger a controller-change reload that destroys the JS context.
  defp assert_connected(session) do
    assert_has(session, "body .phx-connected")
  end

  defp run_js(session, script) do
    PhoenixTest.Playwright.evaluate(session, script, fn _ -> :ok end)
    session
  end
end
