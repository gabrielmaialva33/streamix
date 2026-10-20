defmodule StreamixWeb.PageHeadersTest do
  use StreamixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures

  test "secondary pages expose the shared page heading", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    for {path, id, title} <- [
          {"/favorites", "favorites", "Minha lista"},
          {"/history", "history", "Histórico"},
          {"/guide", "guide", "Guia de TV"},
          {"/plans", "plans", "Planos"},
          {"/settings", "settings", "Configurações"},
          {"/party", "party", "Watch Party"},
          {"/torrent", "torrents", "Torrents"},
          {"/providers", "providers", "Meus provedores"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "##{id}-page-header h1", title)
    end
  end
end
