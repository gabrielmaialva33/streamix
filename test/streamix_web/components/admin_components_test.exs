defmodule StreamixWeb.AdminComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.AdminComponents

  test "localizes known status and role labels" do
    assert render_component(&AdminComponents.status_badge/1, status: "active") =~ "Ativa"
    assert render_component(&AdminComponents.status_badge/1, status: "admin") =~ "Administrador"
    assert render_component(&AdminComponents.status_badge/1, status: "customer") =~ "Cliente"
    assert render_component(&AdminComponents.status_badge/1, status: "moderator") =~ "Moderador"
  end

  test "admin navigation is stable, scrollable, and touch safe" do
    html =
      render_component(&AdminComponents.admin_tabs/1,
        current_path: "/admin"
      )

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "#admin-navigation[aria-label='Administração']") != []
    assert Floki.find(document, "#admin-navigation a.min-h-11") |> length() == 4
    assert html =~ "Cobrança"
  end
end
