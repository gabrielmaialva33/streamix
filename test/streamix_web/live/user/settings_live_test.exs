defmodule StreamixWeb.User.SettingsLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  test "keeps PWA install visible and maintenance inside a collapsed diagnostic", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "App Streamix"
    assert has_element?(view, "#settings-pwa-install[phx-hook='PwaInstall']")
    assert has_element?(view, "#pwa-diagnostics:not([open])", "Diagnóstico do app")
    assert has_element?(view, "#pwa-diagnostics #pwa-repair[phx-hook='PwaRepair']")

    assert has_element?(
             view,
             "#pwa-diagnostics button[data-pwa-repair-action='sync']",
             "Tentar sincronização offline"
           )

    assert has_element?(view, "#adult-content-toggle.size-11[aria-pressed='false']")
  end

  test "groups account and playback controls with the shared checkbox renderer", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#account-settings #email_form")
    assert has_element?(view, "#account-settings #password_form")
    assert has_element?(view, "#playback-preferences #adult-content-toggle")
    assert has_element?(view, "#playback-preferences #subtitle-preferences-form")

    assert has_element?(
             view,
             "#subtitle-preferences-form input[type='hidden'][name='user[subtitles_enabled]'][value='false']"
           )

    assert has_element?(
             view,
             "#subtitle-preferences-form input[type='checkbox'][name='user[subtitles_enabled]'].size-5"
           )
  end

  test "updates subtitle language and auto mode", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#subtitle-preferences-form",
      user: %{subtitle_language: "en", subtitles_enabled: "true"}
    )
    |> render_submit()

    updated = Streamix.Accounts.get_user!(user.id)
    assert updated.subtitle_language == "en"
    assert updated.subtitles_enabled
    refute render(view) =~ "Sincronismo:"
  end
end
