defmodule StreamixWeb.Content.NavigationComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.NavigationComponents

  test "renders the section action as a 44px mobile touch target" do
    html =
      render_component(&NavigationComponents.section_header/1,
        title: "Filmes",
        see_more_path: "/browse/movies"
      )

    assert html =~ "inline-flex"
    assert html =~ "min-h-11"
  end
end
