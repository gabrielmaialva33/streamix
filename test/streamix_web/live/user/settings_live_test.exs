defmodule StreamixWeb.User.SettingsLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  test "renders PWA repair tools for authenticated users", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:ok, _lv, html} = live(conn, ~p"/settings")
    assert html =~ "App no iPhone"
    assert html =~ "Atualizar app e limpar cache"
    assert html =~ "phx-hook=\"PwaRepair\""
  end

  test "updates subtitle language, auto mode and sync offset", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#subtitle-preferences-form",
      user: %{subtitle_language: "en", subtitles_enabled: "true"}
    )
    |> render_submit()

    render_click(view, "adjust_subtitle_offset", %{"delta" => "500"})

    updated = Streamix.Accounts.get_user!(user.id)
    assert updated.subtitle_language == "en"
    assert updated.subtitles_enabled
    assert updated.subtitle_offset_ms == 500
    assert render(view) =~ "Sincronismo: +0.5s"
  end
end
