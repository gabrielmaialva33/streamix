defmodule StreamixWeb.ErrorHTMLTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(StreamixWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Página não encontrada"
    assert html =~ "404"
    assert html =~ "Voltar ao início"
  end

  test "renders 500.html" do
    html = render_to_string(StreamixWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Algo deu errado"
    assert html =~ "500"
    assert html =~ "Voltar ao início"
  end

  test "GET /pagina-inexistente renders 404 inside root layout with title and app stylesheet", %{
    conn: conn
  } do
    conn = get(conn, "/pagina-inexistente")
    html = html_response(conn, 404)

    assert html =~ "<title"
    assert html =~ "/assets/css/app.css"
    assert html =~ "Página não encontrada"
    assert html =~ "Voltar ao início"
    refute html =~ "/images/metronic/illustrations/"
  end
end
