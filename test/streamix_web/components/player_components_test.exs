defmodule StreamixWeb.PlayerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.PlayerComponents

  test "keeps VOD controls in the bottom bar with centered loading indicator and Netflix skips" do
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
    assert Floki.find(document, "#player-bottom-controls #loading-indicator") == []
    assert Floki.find(document, "#loading-indicator.absolute") != []
    assert Floki.find(document, "#loading-indicator .animate-spin") != []
    assert Floki.find(document, "#player-bottom-controls #tracks-btn") != []
    assert Floki.find(document, "#player-bottom-controls #settings-btn") != []
    assert Floki.find(document, "#center-play") == []

    # Netflix's ±10 s: in the bar, and again in the touch-only centre row.
    assert Floki.find(
             document,
             "#player-primary-controls #player-bar-seek-backward-btn[data-player-action='seek-backward']"
           ) != []

    assert Floki.find(
             document,
             "#player-primary-controls #player-bar-seek-forward-btn[data-player-action='seek-forward']"
           ) != []

    assert Floki.find(document, "#player-center-controls[data-player-touch-only]") != []
    assert Floki.find(document, "#player-center-play-btn[data-player-action='toggle-play']") != []
    assert Floki.find(document, "#pip-btn[aria-pressed=false].hidden") != []

    assert [{"video", video_attributes, _children}] =
             Floki.find(document, "#video-element")

    assert {"preload", "none"} in video_attributes
    refute List.keymember?(video_attributes, "disablepictureinpicture", 0)

    assert Floki.find(document, "#player-close-btn.size-12[aria-label='Voltar']") != []

    assert Floki.find(
             document,
             "#player-lock-btn[data-player-action='lock'][data-player-touch-only]"
           ) != []

    assert Floki.find(document, "#player-fit-btn[data-player-action='fit-toggle']") != []
    assert Floki.find(document, "#player-unlock-btn[data-player-action='unlock']") != []

    # No series, no episodes button or panel; no next episode, no shortcut.
    assert Floki.find(document, "#player-episodes-btn") == []
    assert Floki.find(document, "#player-episodes-layer") == []
    assert Floki.find(document, "#player-next-episode-btn") == []
  end

  test "hands the player a picture to show until the first frame" do
    movie =
      render_component(&PlayerComponents.video_player/1,
        content: %{
          id: 42,
          name: "Filme",
          stream_icon: "https://image.tmdb.org/t/p/w500/poster.jpg",
          assets: [
            %{asset_type: "backdrop", position: 1, url: "https://image.tmdb.org/t/p/w1280/b.jpg"},
            %{asset_type: "image", position: 0, url: "https://image.tmdb.org/t/p/w500/i.jpg"}
          ]
        },
        content_type: :movie,
        stream_url: "/stream/movie/42"
      )

    assert [poster] =
             movie
             |> Floki.parse_fragment!()
             |> Floki.attribute("#video-player-container", "data-player-poster")

    # The wide backdrop wins over the portrait cover, through the image proxy.
    assert poster =~ "b.jpg"
    refute poster =~ "poster.jpg"

    channel =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 7, name: "Canal", stream_icon: "https://example.com/logo.png"},
        content_type: :live_channel,
        stream_url: "/stream/live/7"
      )

    assert channel
           |> Floki.parse_fragment!()
           |> Floki.attribute("#video-player-container", "data-player-poster") == []
  end

  test "pause screen reminds what is playing, with the synopsis" do
    document =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme de teste", title: "Filme de teste"},
        content_type: :movie,
        stream_url: "/stream/movie/42",
        synopsis: "Uma família viaja pelo litoral."
      )
      |> Floki.parse_fragment!()

    pause_info = Floki.find(document, "#player-pause-info")
    assert Floki.text(pause_info) =~ "Você está assistindo"
    assert Floki.text(pause_info) =~ "Filme de teste"
    assert Floki.text(pause_info) =~ "Uma família viaja pelo litoral."
  end

  test "episodes panel lists the season with progress and the current episode" do
    document =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 2, name: "Piloto", title: "Piloto"},
        content_type: :episode,
        stream_url: "/stream/episode/2",
        next_episode: %{
          id: 3,
          title: "Segundo",
          episode_num: 3,
          season_num: 1,
          series_name: "Série",
          cover: nil,
          stream_url: "/stream/episode/3",
          type: "episode"
        },
        season_episodes: [
          %{
            id: 1,
            number: 1,
            title: "Começo",
            plot: nil,
            image: nil,
            path: "/watch/episode/1",
            progress: 1.0,
            current: false
          },
          %{
            id: 2,
            number: 2,
            title: "Piloto",
            plot: "Tudo começa aqui.",
            image: nil,
            path: "/watch/episode/2",
            progress: 0.4,
            current: true
          }
        ]
      )
      |> Floki.parse_fragment!()

    assert Floki.find(document, "#player-episodes-btn[data-player-action='episodes']") != []

    assert Floki.find(document, "#player-next-episode-btn[data-player-action='next-episode']") !=
             []

    assert Floki.find(document, "#player-episodes-panel[role='dialog']") != []
    assert Floki.find(document, "#player-episodes-layer [data-player-action='close-panel']") != []

    assert [_, _] = Floki.find(document, "#player-episodes-panel li a")
    assert [current] = Floki.find(document, "#player-episodes-panel a[aria-current='true']")
    assert Floki.attribute(current, "href") == ["/watch/episode/2"]
    assert Floki.text(current) =~ "Assistindo agora"

    assert Floki.find(
             document,
             "#player-episodes-panel a[href='/watch/episode/2'] [style='width: 40%']"
           ) != []
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
    assert Floki.find(document, "#player-center-play-btn[disabled]") != []
    assert [_, _, _, _] = Floki.find(document, "[data-player-action^='seek-'][disabled]")
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
    assert Floki.find(document, "[data-player-action^='seek-']") == []
    assert Floki.find(document, "#player-center-controls") == []
  end

  test "timeline progress container is rendered as an accessible slider (A2-C11)" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme", title: "Filme"},
        content_type: :movie,
        stream_url: "/stream/movie/42"
      )

    document = Floki.parse_fragment!(html)
    assert [{"div", attrs, _}] = Floki.find(document, "#progress-container")
    assert {"role", "slider"} in attrs
    assert {"tabindex", "0"} in attrs
    assert {"aria-label", "Posição do vídeo"} in attrs
    assert {"aria-valuemin", "0"} in attrs
    assert {"aria-valuemax", "0"} in attrs
    assert {"aria-valuenow", "0"} in attrs
    assert {"aria-valuetext", "00:00 de 00:00"} in attrs
  end

  test "renders error state with exit button and spacer pointer-events-none (AGY-07, AGY-12)" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme", title: "Filme"},
        content_type: :movie,
        stream_url: "/stream/movie/42",
        on_close: "close_player"
      )

    document = Floki.parse_fragment!(html)

    # Error container is elevated to z-40 with pointer-events-auto
    assert [{"div", error_attrs, _}] = Floki.find(document, "#error-container")
    error_class = List.keyfind(error_attrs, "class", 0) |> elem(1)
    assert error_class =~ "z-40"
    assert error_class =~ "pointer-events-auto"

    # Retry and Back buttons are present
    assert Floki.find(document, "#error-container .retry-btn") != []
    assert Floki.find(document, "#error-container #player-error-back-btn") != []

    # Middle spacer in player controls does not intercept pointer events
    # Middle spacer in player controls does not intercept pointer events
    # The middle band holds the touch play row, so it is not aria-hidden, but
    # it must still let a click through to the video.
    assert [{"div", spacer_attrs, _}] = Floki.find(document, "#player-controls > .flex-1")

    spacer_class = List.keyfind(spacer_attrs, "class", 0) |> elem(1)
    assert spacer_class =~ "pointer-events-none"
  end

  test "renders autoplay blocked, ended, and resume overlays (CL2-01, AGY-10, AGY-11)" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme", title: "Filme"},
        content_type: :movie,
        stream_url: "/stream/movie/42",
        on_close: "close_player"
      )

    document = Floki.parse_fragment!(html)

    # Autoplay overlay
    assert Floki.find(document, "#autoplay-overlay") != []
    assert Floki.find(document, "#autoplay-overlay #autoplay-play-btn") != []

    # Ended overlay
    assert Floki.find(document, "#ended-overlay") != []
    assert Floki.find(document, "#ended-overlay #ended-replay-btn") != []
    assert Floki.find(document, "#ended-overlay #ended-back-btn") != []

    # Resume toast
    assert Floki.find(document, "#resume-toast") != []
    assert Floki.find(document, "#resume-toast #resume-restart-btn") != []
    assert Floki.find(document, "#resume-toast #resume-time-text") != []
  end

  test "renders live channel subtext when no epg program is present (AGY-13)" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 10, name: "Globo HD"},
        content_type: :live_channel,
        stream_url: "/stream/live/10"
      )

    document = Floki.parse_fragment!(html)
    assert Floki.text(Floki.find(document, ".player-title")) =~ "Programação ao vivo"
  end

  test "renders next episode overlay with dialog role and 44px buttons (AGY-09)" do
    next_ep = %{
      id: 99,
      title: "Próximo Ep",
      season_num: 1,
      episode_num: 2,
      series_name: "Série",
      cover: nil
    }

    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Episódio 1", title: "Episódio 1"},
        content_type: :episode,
        stream_url: "/stream/episode/42",
        next_episode: next_ep
      )

    document = Floki.parse_fragment!(html)

    assert [{"div", overlay_attrs, _}] = Floki.find(document, "#next-episode-overlay")
    assert {"role", "dialog"} in overlay_attrs
    assert {"aria-live", "polite"} in overlay_attrs
    assert {"aria-label", "Próximo episódio"} in overlay_attrs

    assert [{"button", play_attrs, _}] = Floki.find(document, "#play-next-btn")
    play_class = List.keyfind(play_attrs, "class", 0) |> elem(1)
    assert play_class =~ "min-h-11"

    assert [{"button", cancel_attrs, _}] = Floki.find(document, "#cancel-next-btn")
    cancel_class = List.keyfind(cancel_attrs, "class", 0) |> elem(1)
    assert cancel_class =~ "min-h-11"
  end

  test "tracks menu is clamped on mobile to prevent left-edge breakout (AGY-08)" do
    html =
      render_component(&PlayerComponents.video_player/1,
        content: %{id: 42, name: "Filme", title: "Filme"},
        content_type: :movie,
        stream_url: "/stream/movie/42"
      )

    document = Floki.parse_fragment!(html)
    assert [{"div", menu_attrs, _}] = Floki.find(document, "#tracks-menu")
    menu_class = List.keyfind(menu_attrs, "class", 0) |> elem(1)
    assert menu_class =~ "max-w-[calc(100vw-2rem)]"
    assert menu_class =~ "-right-12 sm:right-0"
  end
end
