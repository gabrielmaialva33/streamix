defmodule StreamixWeb.App.NavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.App.Navigation

  defp render_nav(current_path) do
    (&Navigation.mobile_bottom_nav/1)
    |> render_component(home_path: "/home", current_path: current_path)
    |> Floki.parse_fragment!()
  end

  test "renders four tabs and Mais with one active destination" do
    document = render_nav("/favorites")

    assert length(Floki.find(document, "#mobile-bottom-nav > div > a")) == 4
    assert Floki.find(document, "#mobile-tab-more[popovertarget='mobile-more-sheet']") != []
    assert length(Floki.find(document, "#mobile-bottom-nav [aria-current='page']")) == 1
    assert Floki.find(document, "#mobile-tab-favorites[aria-current='page']") != []
    assert Floki.find(document, "#mobile-tab-search[aria-label='Busca']") != []
  end

  test "Mais reaches what the desktop header offers beyond the tabs" do
    document = render_nav("/home")

    hrefs =
      document
      |> Floki.find("#mobile-more-sheet[popover] a")
      |> Enum.flat_map(&Floki.attribute(&1, "href"))

    assert hrefs == ["/guide", "/torrent", "/party", "/history", "/providers", "/settings"]
    assert Floki.find(document, "#mobile-tab-more[aria-current='page']") == []
  end

  test "Mais is the active tab on the pages it holds" do
    document = render_nav("/guide")

    assert Floki.find(document, "#mobile-tab-more[aria-current='page']") != []
    assert Floki.find(document, "#mobile-more-guide[aria-current='page']") != []
    assert Floki.find(document, "#mobile-tab-catalog[aria-current='page']") == []
  end
end
