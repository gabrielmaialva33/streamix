defmodule StreamixWeb.LiveSessionNavigationTest do
  use ExUnit.Case, async: true

  alias StreamixWeb.LiveSessionNavigation

  test "keeps authenticated catalog navigation inside one session" do
    assert LiveSessionNavigation.same_session?(
             "/browse/movies?provider=all",
             "/browse/series/42"
           )
  end

  test "detects public, admin, and player boundaries" do
    refute LiveSessionNavigation.same_session?("/browse", "/")
    refute LiveSessionNavigation.same_session?("/browse", "/admin")
    refute LiveSessionNavigation.same_session?("/browse", "/watch/movie/42")
    refute LiveSessionNavigation.same_session?("/party", "/party/ABC123/watch")
  end

  test "treats query strings as part of the underlying route session" do
    assert LiveSessionNavigation.same_session?("/plans", "/plans?upgrade=screens")
    assert LiveSessionNavigation.same_session?("/search", "/browse?source=gindex")
  end
end
