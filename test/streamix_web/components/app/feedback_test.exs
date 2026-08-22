defmodule StreamixWeb.App.FeedbackTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.App.Feedback

  test "renders controlled infinite scroll with an accessible manual fallback" do
    document =
      render_component(&Feedback.infinite_scroll_sentinel/1,
        id: "movies-sentinel",
        page: 3,
        sync_page_url: true,
        stream_target: "#movies",
        auto_loads: 2
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(document, "#movies-sentinel", "phx-hook") == ["InfiniteScroll"]
    assert Floki.attribute(document, "#movies-sentinel", "data-page") == ["3"]
    assert Floki.attribute(document, "#movies-sentinel", "data-sync-page-url") == ["true"]
    assert Floki.attribute(document, "#movies-sentinel", "data-auto-loads") == ["2"]

    assert Floki.attribute(
             document,
             "#movies-sentinel [data-infinite-scroll-manual]",
             "aria-controls"
           ) == ["movies"]

    assert Floki.attribute(
             document,
             "#movies-sentinel [data-infinite-scroll-manual]",
             "hidden"
           ) != []

    assert Floki.find(
             document,
             "#movies-sentinel [data-infinite-scroll-status][aria-live='polite']"
           ) !=
             []
  end
end
