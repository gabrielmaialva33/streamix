defmodule StreamixWeb.PlayerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.PlayerComponents

  test "keeps VOD controls and loading status in the bottom bar without seek buttons" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme de teste", title: "Filme de teste"},
        content_type: :movie,
        stream_url: "/stream/movie/42",
        on_close: "close_player"
      )

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "#player-bottom-controls #player-primary-controls") != []
    assert Floki.find(document, "#player-bottom-controls #play-pause-btn") != []
    assert Floki.find(document, "#player-bottom-controls #loading-indicator") != []
    assert Floki.find(document, "#loading-indicator.absolute") == []
    assert Floki.find(document, "#center-play") == []
    assert Floki.find(document, "#seek-backward-btn") == []
    assert Floki.find(document, "#seek-forward-btn") == []

    assert Floki.find(document, "#player-close-btn.size-12") != []
  end

  test "keeps live playback non-seekable" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 7, name: "Canal ao vivo"},
        content_type: :live_channel,
        stream_url: "/stream/live/7"
      )

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "#player-bottom-controls #player-primary-controls") != []
    assert Floki.find(document, "#player-bottom-controls #play-pause-btn") != []
    assert Floki.find(document, "#center-play") == []
  end
end
