defmodule StreamixWeb.Content.DetailComponents.ActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.DetailComponents.Actions

  test "the play button carries the stream hints the browser warms its engine from" do
    html =
      render_component(&Actions.play_button/1,
        event: "play_movie",
        label: "Assistir",
        stream_type: "mkv",
        source_type: "gindex",
        provider_id: 2
      )

    [button] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[data-playback-warm]")
      |> Enum.to_list()

    assert LazyHTML.attribute(button, "data-stream-type") == ["mkv"]
    assert LazyHTML.attribute(button, "data-source-type") == ["gindex"]
    assert LazyHTML.attribute(button, "data-provider-id") == ["2"]
    assert LazyHTML.attribute(button, "phx-click") == ["play_movie"]
  end

  test "hints are optional" do
    html =
      render_component(&Actions.play_button/1, event: "play_first_episode", label: "Assistir")

    button = html |> LazyHTML.from_fragment() |> LazyHTML.query("button[data-playback-warm]")

    assert LazyHTML.attribute(button, "data-stream-type") == []
  end
end
