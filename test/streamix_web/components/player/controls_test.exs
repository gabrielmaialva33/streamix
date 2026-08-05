defmodule StreamixWeb.PlayerComponents.ControlsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.PlayerComponents.Controls

  test "renders accessible primary playback controls" do
    volume = render_component(&Controls.volume_control/1, %{}) |> Floki.parse_fragment!()
    playback = render_component(&Controls.play_pause_button/1, %{}) |> Floki.parse_fragment!()

    assert Floki.find(volume, "#mute-btn[aria-pressed='false']") != []
    assert Floki.find(volume, "#volume-slider[aria-label='Volume']") != []
    assert Floki.find(playback, "#play-pause-btn[aria-label='Reproduzir ou pausar']") != []
  end

  test "formats subtitle synchronization and keeps client-side aspect choices" do
    document =
      render_component(&Controls.settings_button/1, subtitle_offset_ms: 1_500)
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(document, "#subtitle-sync-value")) =~ "+1.5s"
    assert length(Floki.find(document, "#aspect-options [data-aspect-mode]")) == 5
  end
end
