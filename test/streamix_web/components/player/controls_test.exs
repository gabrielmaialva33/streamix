defmodule StreamixWeb.PlayerComponents.ControlsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.PlayerComponents.Controls

  test "renders accessible primary playback controls with mobile touch targets" do
    volume = render_component(&Controls.volume_control/1, %{}) |> Floki.parse_fragment!()
    playback = render_component(&Controls.play_pause_button/1, %{}) |> Floki.parse_fragment!()

    assert Floki.find(volume, "#mute-btn[aria-pressed='false']") != []
    assert Floki.find(volume, "#mute-btn.player-control-btn.min-h-11.min-w-11") != []
    assert Floki.find(volume, "#volume-slider[aria-label='Volume']") != []
    assert Floki.find(playback, "#play-pause-btn[aria-label='Reproduzir ou pausar']") != []
    assert Floki.find(playback, "#play-pause-btn.player-control-btn.min-h-11.min-w-11") != []
  end

  test "renders dedicated tracks button with quick toggle, sync offset, and audio/subtitle sections" do
    document =
      render_component(&Controls.tracks_button/1, subtitle_offset_ms: 1_500)
      |> Floki.parse_fragment!()

    assert Floki.find(document, "#tracks-btn[aria-label='Áudio e legendas']") != []
    assert Floki.find(document, "#tracks-btn.player-control-btn.min-h-11.min-w-11") != []
    assert Floki.find(document, "#tracks-menu") != []
    assert Floki.find(document, "#tracks-empty") != []
    assert Floki.find(document, "#audio-section") != []
    assert Floki.find(document, "#subtitle-section") != []
    assert Floki.find(document, "#quick-subtitles-toggle-btn") != []
    assert Floki.find(document, "#subtitle-sync-controls") != []
    assert Floki.text(Floki.find(document, "#subtitle-sync-value")) =~ "+1.5s"
  end

  test "renders settings button with quality and client-side aspect choices" do
    document =
      render_component(&Controls.settings_button/1, %{})
      |> Floki.parse_fragment!()

    assert Floki.find(document, "#settings-btn[aria-label='Configurações']") != []
    assert Floki.find(document, "#settings-btn.player-control-btn.min-h-11.min-w-11") != []
    assert Floki.find(document, "#quality-options") != []
    assert length(Floki.find(document, "#aspect-options [data-aspect-mode]")) == 5
  end
end
