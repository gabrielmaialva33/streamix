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
    assert Floki.find(document, "#pip-btn[aria-pressed=false].hidden") != []

    assert [{"video", video_attributes, _children}] =
             Floki.find(document, "#video-element")

    assert {"preload", "none"} in video_attributes
    refute List.keymember?(video_attributes, "disablepictureinpicture", 0)

    assert Floki.find(document, "#player-close-btn.size-12") != []
  end

  test "renders viewer transport controls locked before JavaScript mounts" do
    document =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme de teste", title: "Filme de teste"},
        content_type: :movie,
        stream_url: "/stream/movie/42",
        party_mode: true,
        party_role: :viewer
      )
      |> Floki.parse_fragment!()

    assert Floki.find(document, "#video-player-container[data-party-role='viewer']") != []
    assert Floki.find(document, "#play-pause-btn[disabled]") != []
    assert Floki.find(document, "#progress-container[aria-disabled='true']") != []
    assert Floki.find(document, "#speed-btn[disabled]") != []
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
