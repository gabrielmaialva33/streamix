defmodule StreamixWeb.E2E.GuideMarkerTest do
  use PhoenixTest.Playwright.Case, async: false

  @endpoint StreamixWeb.Endpoint
  @moduletag :playwright
  setup {StreamixWeb.PlaywrightSupport, :register_context_cleanup}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import StreamixWeb.ConnCase, only: [log_in_user: 2]

  alias PlaywrightEx.BrowserContext

  setup %{conn: session} do
    user = user_fixture()
    provider = provider_fixture(user)
    channel_fixture(provider, %{epg_channel_id: "marker-fixture", name: "Canal Notícias"})
    now = DateTime.utc_now()

    epg_program_fixture(provider, %{
      epg_channel_id: "marker-fixture",
      title: "Jornal da tarde — notícias e entrevistas",
      start_time: DateTime.add(now, -30, :minute),
      end_time: DateTime.add(now, 120, :minute)
    })

    cookie =
      build_conn()
      |> log_in_user(user)
      |> get("/guide")
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!("_streamix_key")

    session =
      PhoenixTest.Playwright.unwrap(session, fn %{context_id: context_id} ->
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

    %{conn: session}
  end

  @tag browser_context_opts: [viewport: %{width: 1440, height: 1000}]
  test "desktop now line runs behind the programmes, never over their text", %{conn: session} do
    session
    |> visit("/guide")
    |> assert_has("[data-current-program=true]")
    |> PhoenixTest.Playwright.screenshot("guide-marker-1440.png")
    |> PhoenixTest.Playwright.evaluate(
      """
      () => {
        const marker = document.querySelector('.guide-now-line');
        const rect = marker.getBoundingClientRect();
        const program = document.querySelector('[data-current-program=true]').getBoundingClientRect();
        // Hit-test with the marker made hittable: whatever paints on top wins.
        marker.parentElement.style.pointerEvents = 'auto';
        marker.style.pointerEvents = 'auto';
        const onProgram = document.elementFromPoint(rect.left + rect.width / 2, program.top + program.height / 2);
        marker.parentElement.style.pointerEvents = '';
        marker.style.pointerEvents = '';
        return {
          display: getComputedStyle(marker).display,
          background: getComputedStyle(marker).backgroundColor,
          crosses: rect.left > program.left && rect.right < program.right,
          // The programme (and its title) paints over the line.
          coveredByProgram: !!(onProgram && onProgram.closest('[data-guide-program]')),
          overflow: document.documentElement.scrollWidth - innerWidth
        };
      }
      """,
      [is_function: true],
      fn result ->
        # The old full-height red marker was drawn over titles.
        assert result["display"] == "block"
        assert result["crosses"]
        assert result["background"] != "rgba(0, 0, 0, 0)"
        assert result["coveredByProgram"]
        assert result["overflow"] <= 1
      end
    )
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "phone keeps compact scrolling programme cards without the desktop marker", %{
    conn: session
  } do
    session
    |> visit("/guide")
    |> assert_has("[data-current-program=true]")
    |> PhoenixTest.Playwright.screenshot("guide-marker-390.png")
    |> PhoenixTest.Playwright.evaluate(
      """
      () => ({display: getComputedStyle(document.querySelector('.guide-now-line')).display,
        overflow: document.documentElement.scrollWidth - innerWidth})
      """,
      [is_function: true],
      fn result ->
        assert result["display"] == "none"
        assert result["overflow"] <= 1
      end
    )
  end
end
