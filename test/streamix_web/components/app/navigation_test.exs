defmodule StreamixWeb.App.NavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.App.Navigation

  test "renders five semantic mobile tabs with one active destination" do
    html =
      render_component(&Navigation.mobile_bottom_nav/1,
        home_path: "/home",
        current_path: "/favorites"
      )

    document = Floki.parse_fragment!(html)

    assert length(Floki.find(document, "#mobile-bottom-nav a")) == 5
    assert length(Floki.find(document, "#mobile-bottom-nav a[aria-current='page']")) == 1
    assert Floki.find(document, "#mobile-tab-favorites[aria-current='page']") != []
    assert Floki.find(document, "#mobile-tab-search[aria-label='Busca']") != []
  end
end
