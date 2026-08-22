defmodule StreamixWeb.PlayerComponents do
  @moduledoc """
  Video player UI components for Streamix.
  Netflix-style player with pure Tailwind CSS.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents
  import StreamixWeb.PlayerComponents.Controls

  alias StreamixWeb.Helpers.ImageProxy
  alias StreamixWeb.PlayerComponents.Metadata

  alias Phoenix.LiveView.JS

  @doc """
  Renders the main video player with all controls.
  """
  attr :content, :map, required: true

  attr :content_type, :atom,
    required: true,
    values: [:live, :live_channel, :movie, :episode, :gindex, :gindex_episode, :torrent]

  attr :stream_url, :string, required: true
  attr :streaming_mode, :atom, default: :balanced
  attr :fullscreen, :boolean, default: false
  attr :on_close, :string, default: nil
  attr :show_controls, :boolean, default: true
  attr :provider_type, :string, default: nil
  attr :next_episode, :map, default: nil
  attr :expected_duration, :integer, default: 0
  attr :subtitles_enabled, :boolean, default: true
  attr :subtitle_language, :string, default: "pt-BR"
  attr :subtitle_offset_ms, :integer, default: 0
  attr :party_mode, :boolean, default: false
  attr :party_role, :atom, default: :none, values: [:none, :host, :viewer]

  def video_player(assigns) do
    # Use external nginx proxy for HTTP streams (except GIndex which plays directly)
    proxy_url = Metadata.proxy_url(assigns.stream_url, assigns.content_type)
    content_type_str = if assigns.content_type in [:live, :live_channel], do: "live", else: "vod"
    # Provider type for JS player (gindex/xtream) - used for codec detection
    source_type = assigns.provider_type || Atom.to_string(assigns.content_type)

    # Explicit stream type hint for token-based URLs where extension is not in the URL
    stream_type = Metadata.stream_type_hint(assigns.content_type, assigns.content, source_type)

    # Encode next episode data as JSON for JS
    next_episode_json =
      if assigns.next_episode do
        Jason.encode!(assigns.next_episode)
      else
        nil
      end

    assigns =
      assigns
      |> assign(:proxy_url, proxy_url)
      |> assign(:content_type_str, content_type_str)
      |> assign(:source_type, source_type)
      |> assign(:stream_type, stream_type)
      |> assign(:next_episode_json, next_episode_json)
      |> assign(:media_title, Metadata.title(assigns.content, assigns.content_type))
      |> assign(:media_subtitle, Metadata.subtitle(assigns.content, assigns.content_type))
      |> assign(:episode_subtitle, Metadata.episode_subtitle(assigns.content))
      |> assign(:party_transport_locked, assigns.party_mode and assigns.party_role == :viewer)
      |> assign(
        :player_lifecycle_logs,
        Application.get_env(:streamix, :player_lifecycle_logs, false) |> to_string()
      )
      |> assign(
        :feature_avbridge,
        Application.get_env(:streamix, :feature_avbridge, false) |> to_string()
      )
      |> assign(
        :feature_h265web,
        Application.get_env(:streamix, :feature_h265web, false) |> to_string()
      )
      # Tier hint that the JS engine_selector keys off so we route only
      # the heavy 4K HEVC content through the GPU path. Anything else
      # plays just fine on AVPlayer (libmedia) and we keep the bundle
      # off the critical path.
      |> assign(:uhd_hevc, Metadata.uhd_hevc?(assigns.content) |> to_string())

    ~H"""
    <div
      id="video-player-container"
      class="relative w-full h-full bg-black group/player"
      phx-hook="VideoPlayer"
      phx-update="ignore"
      data-stream-url={@stream_url}
      data-proxy-url={@proxy_url}
      data-content-type={@content_type_str}
      data-source-type={@source_type}
      data-content-id={@content.id}
      data-streaming-mode={@streaming_mode}
      data-next-episode={@next_episode_json}
      data-expected-duration={@expected_duration}
      data-stream-type={@stream_type}
      data-player-lifecycle-logs={@player_lifecycle_logs}
      data-feature-avbridge={@feature_avbridge}
      data-feature-h265web={@feature_h265web}
      data-uhd-hevc={@uhd_hevc}
      data-media-title={@media_title}
      data-media-subtitle={@media_subtitle}
      data-imdb-id={Map.get(@content, :imdb_id)}
      data-subtitles-enabled={to_string(@subtitles_enabled)}
      data-subtitle-lang={@subtitle_language}
      data-subtitle-offset-ms={@subtitle_offset_ms}
      data-party-mode={to_string(@party_mode)}
      data-party-role={@party_role}
    >
      <%!-- Error container --%>
      <div
        id="error-container"
        class="absolute inset-0 flex items-center justify-center bg-black/80 z-20 hidden"
      >
        <div class="flex flex-col items-center gap-4 text-center p-6">
          <.icon name="hero-exclamation-triangle" class="size-16 text-error" />
          <p class="error-message text-white text-lg">Erro ao carregar</p>
          <p class="error-hint hidden max-w-sm text-sm text-white/65"></p>
          <button
            type="button"
            class="retry-btn px-6 py-2 bg-brand hover:bg-brand/80 text-white rounded-lg font-medium transition-colors"
          >
            Tentar novamente
          </button>
        </div>
      </div>

      <%!-- AVPlayer mount point. AVPlayer renders its canvas inside
           this div. Declared server-side with `phx-update="ignore"`
           so any LiveView patch (watch-party presence ticks, chat
           stream updates, sync beacons) keeps the canvas intact —
           if we let the JS hook `appendChild` a stranger node, the
           next diff wipes it and you end up with audio-only. --%>
      <div
        id="avplayer-mount"
        phx-update="ignore"
        class="absolute inset-0 z-0 hidden"
      />

      <%!-- h265web.js mount point. Same trick as avplayer-mount above:
           h265web injects its own <canvas> inside this div, so we keep
           it under `phx-update="ignore"` to survive LiveView patches.
           Hidden by default; `playWithH265web` flips it visible and
           hides the native <video> below. --%>
      <div
        id="h265web-mount"
        phx-update="ignore"
        class="absolute inset-0 z-0 hidden"
      />

      <%!-- Video element. JS starts playback only after resume seek is applied. --%>
      <video
        id="video-element"
        phx-update="ignore"
        class="absolute inset-0 w-full h-full object-contain"
        preload="none"
        playsinline
        webkit-playsinline
        x-webkit-airplay="allow"
      />

      <%!-- Controls overlay --%>
      <div
        :if={@show_controls}
        id="player-controls"
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class="absolute inset-0 z-30 flex flex-col justify-between opacity-0 pointer-events-none group-hover/player:opacity-100 group-hover/player:pointer-events-auto transition-opacity duration-300"
      >
        <%!-- Top bar --%>
        <div
          id="player-top-controls"
          class="player-safe-top bg-gradient-to-b from-black/80 via-black/40 to-transparent"
        >
          <div class="flex items-center justify-between">
            <div class="flex min-w-0 flex-1 items-center gap-2 sm:gap-3">
              <button
                :if={@on_close}
                id="player-close-btn"
                type="button"
                phx-click={@on_close}
                aria-label="Fechar player"
                class="flex size-12 shrink-0 touch-manipulation items-center justify-center rounded-full text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
              >
                <.icon name="hero-x-mark" class="size-6" aria-hidden="true" />
              </button>
              <div class="player-title min-w-0 flex-1 transition-opacity">
                <h2 class="text-base sm:text-xl font-semibold text-white drop-shadow-lg truncate">
                  {@media_title}
                </h2>
                <p :if={@content_type == :episode} class="text-xs sm:text-sm text-white/60">
                  {@episode_subtitle}
                </p>
              </div>
            </div>
          </div>
        </div>

        <div class="flex-1" aria-hidden="true" />

        <%!-- Bottom bar --%>
        <div
          id="player-bottom-controls"
          class="player-safe-bottom bg-gradient-to-t from-black/80 via-black/40 to-transparent transition-opacity"
        >
          <%!-- Loading stays with the controls instead of covering the video. --%>
          <div
            id="loading-indicator"
            class="mb-2 flex items-center gap-2 text-xs text-white/75"
            role="status"
            aria-live="polite"
          >
            <span class="size-2 animate-pulse rounded-full bg-brand" aria-hidden="true" />
            <span>Carregando...</span>
          </div>

          <%!-- Progress bar --%>
          <.progress_bar
            :if={@content_type not in [:live, :live_channel]}
            disabled={@party_transport_locked}
          />

          <%!-- Controls. On phones the row wraps: the clock takes its own line
               above the buttons so the 44px touch targets never get squeezed
               by a long "1:23:45 / 2:10:00" or by the PiP button. --%>
          <div class="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1 sm:flex-nowrap">
            <%!-- Left --%>
            <div id="player-primary-controls" class="flex min-w-0 items-center gap-1 sm:gap-3">
              <.play_pause_button disabled={@party_transport_locked} />
              <.volume_control />
              <.live_badge :if={@content_type in [:live, :live_channel]} />
            </div>

            <.time_display :if={@content_type not in [:live, :live_channel]} />

            <%!-- Right --%>
            <div class="ml-auto flex items-center gap-1 sm:gap-2">
              <.speed_button
                :if={@content_type not in [:live, :live_channel]}
                disabled={@party_transport_locked}
              />
              <.settings_button subtitle_offset_ms={@subtitle_offset_ms} />
              <.pip_button />
              <.fullscreen_button />
            </div>
          </div>
        </div>
      </div>

      <%!-- Next episode overlay (shows when near end) --%>
      <div
        :if={@next_episode}
        id="next-episode-overlay"
        class="absolute bottom-24 right-4 sm:right-8 z-30 hidden opacity-0 transition-all duration-300 transform translate-x-4"
      >
        <div class="bg-neutral-900/95 backdrop-blur-md rounded-lg shadow-2xl border border-white/10 p-4 max-w-xs sm:max-w-sm">
          <div class="flex items-center gap-2 mb-2 text-white/60 text-xs uppercase tracking-wider">
            <.icon name="hero-forward" class="size-4" />
            <span>Próximo episódio</span>
          </div>
          <div class="flex gap-3">
            <div class="relative flex-shrink-0">
              <img
                :if={@next_episode.cover}
                src={ImageProxy.proxy(@next_episode.cover)}
                alt=""
                class="w-24 h-14 sm:w-32 sm:h-18 object-cover rounded"
                loading="lazy"
                decoding="async"
              />
              <div
                :if={!@next_episode.cover}
                class="w-24 h-14 sm:w-32 sm:h-18 bg-white/10 rounded flex items-center justify-center"
              >
                <.icon name="hero-film" class="size-6 text-white/40" />
              </div>
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-white font-medium text-sm truncate">{@next_episode.title}</p>
              <p class="text-white/60 text-xs">
                T{@next_episode.season_num}:E{@next_episode.episode_num}
              </p>
              <p class="text-white/40 text-xs truncate">{@next_episode.series_name}</p>
            </div>
          </div>
          <div class="flex gap-2 mt-3">
            <button
              type="button"
              id="play-next-btn"
              class="flex-1 px-4 py-2 bg-brand hover:bg-brand/80 text-white text-sm font-medium rounded transition-colors"
            >
              Reproduzir
            </button>
            <button
              type="button"
              id="cancel-next-btn"
              class="px-4 py-2 bg-white/10 hover:bg-white/20 text-white text-sm rounded transition-colors"
            >
              Cancelar
            </button>
          </div>
          <%!-- Countdown bar --%>
          <div class="mt-2 h-1 bg-white/20 rounded-full overflow-hidden">
            <div
              id="next-countdown-bar"
              class="h-full bg-brand transition-all duration-1000"
              style="width: 100%"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :content, :map, required: true
  attr :status_url, :string, required: true
  attr :peer_target, :integer, default: 30
  attr :on_close, :string, default: nil

  def torrent_swarm_gate(assigns) do
    assigns = assign(assigns, :content_title, Metadata.title(assigns.content, :torrent))

    ~H"""
    <div
      id="torrent-swarm-gate"
      phx-hook="TorrentSwarmGate"
      data-status-url={@status_url}
      data-peer-target={@peer_target}
      class="absolute inset-0 flex items-center justify-center bg-black"
    >
      <button
        :if={@on_close}
        id="torrent-swarm-close-btn"
        type="button"
        phx-click={@on_close}
        aria-label="Fechar player"
        class="player-safe-corner fixed z-40 flex size-12 touch-manipulation items-center justify-center rounded-full text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
      >
        <.icon name="hero-x-mark" class="size-6" aria-hidden="true" />
      </button>

      <div class="flex w-full max-w-md flex-col items-center gap-5 px-6 text-center">
        <div class="relative">
          <div class="size-16 rounded-full border-4 border-white/10 border-t-brand animate-spin" />
          <.icon name="hero-signal" class="absolute inset-0 m-auto size-7 text-white/80" />
        </div>

        <div class="min-w-0">
          <p class="truncate text-lg font-semibold text-white">
            {@content_title}
          </p>
          <p
            id="torrent-swarm-status"
            class="mt-2 text-sm text-white/70"
          >
            Buffering swarm 0/{@peer_target} peers
          </p>
          <p id="torrent-swarm-detail" class="mt-1 min-h-5 text-xs text-white/50">
            Preparando o motor torrent.
          </p>
        </div>

        <div class="h-1.5 w-full overflow-hidden rounded-full bg-white/10">
          <div
            id="torrent-swarm-progress"
            class="h-full rounded-full bg-brand transition-all duration-300"
            style="width: 0%"
          />
        </div>

        <button
          id="torrent-swarm-retry"
          type="button"
          class="hidden min-h-11 rounded-lg bg-white/10 px-5 py-2.5 text-sm font-medium text-white transition-colors hover:bg-white/20 active:bg-white/25"
        >
          Tentar novamente
        </button>
      </div>
    </div>
    """
  end
end
