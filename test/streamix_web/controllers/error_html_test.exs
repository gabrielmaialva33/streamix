defmodule StreamixWeb.ErrorHTMLTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(StreamixWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Página não encontrada"
    assert html =~ "404"
  end

  test "renders 500.html" do
    html = render_to_string(StreamixWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Algo deu errado"
    assert html =~ "500"
  end
end
