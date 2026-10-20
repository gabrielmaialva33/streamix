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
  test "desktop now marker paints only the gutters, never programme text", %{conn: session} do
    session
    |> visit("/guide")
    |> assert_has("[data-current-program=true]")
    |> PhoenixTest.Playwright.screenshot("guide-marker-1440.png")
    |> PhoenixTest.Playwright.evaluate(
      """
      () => {
        const marker = document.querySelector('.guide-now-line');
        const rect = marker.getBoundingClientRect();
        const bands = ['::before', '::after'].map(pseudo => {
          const style = getComputedStyle(marker, pseudo);
          const height = parseFloat(style.height);
          const top = style.top === 'auto' ? rect.bottom - height : rect.top + parseFloat(style.top);
          return {painted: style.content !== 'none' && style.content !== 'normal', top, bottom: top + height};
        });
        const textRects = [];
        const walker = document.createTreeWalker(marker.parentElement, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          if (!walker.currentNode.textContent.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(walker.currentNode);
          textRects.push(...range.getClientRects());
        }
        return {
          background: getComputedStyle(marker).backgroundColor,
          bands,
          overlaps: bands.some(band => textRects.some(text =>
            rect.left < text.right && rect.right > text.left && band.top < text.bottom && band.bottom > text.top)),
          overflow: document.documentElement.scrollWidth - innerWidth
        };
      }
      """,
      [is_function: true],
      fn result ->
        # The center must be transparent: the old full-height red marker cut through titles.
        assert result["background"] == "rgba(0, 0, 0, 0)"
        assert Enum.all?(result["bands"], & &1["painted"])
        assert Enum.all?(result["bands"], &(&1["bottom"] - &1["top"] == 6))
        refute result["overlaps"]
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
