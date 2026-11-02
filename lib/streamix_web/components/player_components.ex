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
  # Lets the player remember which engine a provider's files need (AC3 audio
  # in MP4 means AVPlayer), so the next title of that provider starts on it.
  attr :provider_id, :integer, default: nil
  attr :next_episode, :map, default: nil
  attr :season_episodes, :list, default: []
  attr :synopsis, :string, default: nil
  attr :expected_duration, :integer, default: 0
  attr :subtitles_enabled, :boolean, default: true
  attr :subtitle_language, :string, default: "pt-BR"
  attr :subtitle_offset_ms, :integer, default: 0
  attr :party_mode, :boolean, default: false
  attr :party_role, :atom, default: :none, values: [:none, :host, :viewer]
  attr :source_failover_enabled, :boolean, default: false

  def video_player(assigns) do
    # Use external nginx proxy for HTTP streams (except GIndex which plays directly)
    proxy_url = Metadata.proxy_url(assigns.stream_url, assigns.content_type)
    content_type_str = if assigns.content_type in [:live, :live_channel], do: "live", else: "vod"
    # Provider type for JS player (gindex/xtream) - used for codec detection
    source_type = assigns.provider_type || Atom.to_string(assigns.content_type)

    # Explicit stream type hint for token-based URLs where extension is not in the URL
    stream_type =
      Metadata.stream_type(assigns.stream_url, assigns.content_type, assigns.content, source_type)

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
      |> assign(:vod?, assigns.content_type not in [:live, :live_channel])
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
      |> assign(:poster, poster_url(assigns.content, assigns.content_type))

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
      data-player-poster={@poster}
      data-provider-id={@provider_id}
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
      data-source-failover-enabled={to_string(@source_failover_enabled)}
    >
      <div
        id="source-failover-status"
        class="pointer-events-none absolute left-1/2 top-[max(4.5rem,env(safe-area-inset-top))] z-20 hidden -translate-x-1/2 rounded-full border border-white/10 bg-black/75 px-4 py-2 text-center text-xs font-medium text-white shadow-xl backdrop-blur-md"
        role="status"
        aria-live="polite"
        data-failover-state="idle"
      >
        <span
          class="mr-1.5 inline-block size-1.5 animate-pulse rounded-full bg-brand"
          aria-hidden="true"
        />
        <span data-source-failover-text>Procurando outra fonte disponível…</span>
      </div>

      <%!-- Error container --%>
      <div
        id="error-container"
        class="pointer-events-auto absolute inset-0 flex items-center justify-center bg-black/80 z-40 hidden"
      >
        <div class="flex flex-col items-center gap-4 text-center p-6">
          <.icon name="hero-exclamation-triangle" class="size-16 text-error" />
          <p class="error-message text-white text-lg">Não conseguimos carregar o vídeo</p>
          <p class="error-hint hidden max-w-sm text-sm text-white/65"></p>
          <div class="flex items-center gap-3">
            <button
              type="button"
              class="retry-btn min-h-11 px-6 py-2.5 bg-brand hover:bg-brand/80 text-white rounded-lg font-medium transition-colors"
            >
              Tentar novamente
            </button>
            <button
              :if={@on_close}
              type="button"
              id="player-error-back-btn"
              phx-click={@on_close}
              class="player-error-back-btn min-h-11 px-6 py-2.5 bg-white/10 hover:bg-white/20 text-white rounded-lg font-medium transition-colors"
            >
              Voltar
            </button>
            <button
              :if={!@on_close}
              type="button"
              id="player-error-back-btn"
              onclick="window.history.length > 1 ? window.history.back() : window.location.href = '/browse'"
              class="player-error-back-btn min-h-11 px-6 py-2.5 bg-white/10 hover:bg-white/20 text-white rounded-lg font-medium transition-colors"
            >
              Voltar
            </button>
          </div>
        </div>
      </div>

      <%!-- Centered buffer spinner (agy-05) --%>
      <div
        id="loading-indicator"
        class="pointer-events-none absolute inset-0 z-20 flex flex-col items-center justify-center gap-4 hidden"
        role="status"
        aria-live="polite"
        aria-label="Carregando vídeo"
      >
        <div class="size-12 rounded-full border-4 border-white/20 border-t-brand animate-spin drop-shadow-md sm:size-14" />
      </div>

      <%!-- Autoplay blocked overlay (CL2-01) --%>
      <div
        id="autoplay-overlay"
        class="pointer-events-auto absolute inset-0 z-30 flex items-center justify-center bg-black/40 hidden"
        role="dialog"
        aria-modal="false"
        aria-label="Reprodução pausada"
      >
        <button
          type="button"
          id="autoplay-play-btn"
          aria-label="Iniciar reprodução"
          class="flex size-20 min-h-11 min-w-11 items-center justify-center rounded-full bg-brand text-white shadow-2xl transition-all hover:scale-110 hover:bg-brand-hover active:scale-95 focus:outline-none focus:ring-4 focus:ring-brand/50 sm:size-24"
        >
          <.icon name="hero-play-solid" class="size-10 sm:size-12 translate-x-0.5" aria-hidden="true" />
        </button>
      </div>

      <%!-- End of playback overlay (AGY-11) --%>
      <div
        id="ended-overlay"
        class="pointer-events-auto absolute inset-0 z-30 flex items-center justify-center bg-black/85 hidden"
        role="dialog"
        aria-modal="false"
        aria-label="Reprodução finalizada"
      >
        <div class="flex flex-col items-center gap-4 text-center p-6 max-w-sm">
          <.icon name="hero-check-circle" class="size-16 text-brand" />
          <h3 class="text-xl font-bold text-white">Reprodução finalizada</h3>
          <p class="text-sm text-white/60">Você chegou ao final do vídeo.</p>
          <div class="flex items-center gap-3 mt-2">
            <button
              type="button"
              id="ended-replay-btn"
              class="min-h-11 px-5 py-2.5 bg-brand hover:bg-brand/80 text-white font-medium rounded-lg transition-colors flex items-center gap-2"
            >
              <.icon name="hero-arrow-path" class="size-4" />
              <span>Assistir novamente</span>
            </button>
            <button
              :if={@on_close}
              type="button"
              id="ended-back-btn"
              phx-click={@on_close}
              class="min-h-11 px-5 py-2.5 bg-white/10 hover:bg-white/20 text-white font-medium rounded-lg transition-colors"
            >
              Voltar
            </button>
            <button
              :if={!@on_close}
              type="button"
              id="ended-back-btn"
              onclick="window.history.length > 1 ? window.history.back() : window.location.href = '/browse'"
              class="min-h-11 px-5 py-2.5 bg-white/10 hover:bg-white/20 text-white font-medium rounded-lg transition-colors"
            >
              Voltar
            </button>
          </div>
        </div>
      </div>

      <%!-- Auto-resume toast (AGY-10) --%>
      <div
        id="resume-toast"
        class="pointer-events-auto absolute bottom-24 left-4 sm:left-8 z-30 hidden opacity-0 transition-all duration-300 transform -translate-y-2 rounded-lg bg-neutral-900/95 px-4 py-2.5 text-white shadow-2xl border border-white/10 backdrop-blur-md flex items-center gap-3"
        role="status"
        aria-live="polite"
      >
        <span class="text-xs sm:text-sm text-white/90">
          Continuando de <span id="resume-time-text" class="font-semibold text-brand">00:00</span>
        </span>
        <button
          type="button"
          id="resume-restart-btn"
          class="rounded bg-white/15 px-2.5 py-1 text-xs font-medium text-white hover:bg-white/25 active:scale-95 transition-all"
        >
          Recomeçar
        </button>
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
                aria-label="Voltar"
                class="player-control-btn flex size-12 min-h-12 min-w-12 shrink-0 touch-manipulation items-center justify-center rounded-full bg-black/35 text-white/90 backdrop-blur-xs transition-all hover:bg-black/50 hover:text-white active:scale-95 active:bg-black/60 sm:size-11 sm:min-h-0 sm:min-w-0 sm:bg-transparent sm:backdrop-blur-none sm:hover:bg-white/10 sm:active:scale-100 sm:active:bg-white/20"
              >
                <.icon name="hero-arrow-left" class="size-7" aria-hidden="true" />
              </button>
              <div class="player-title min-w-0 flex-1 transition-opacity sm:hidden">
                <h2 class="text-base sm:text-xl font-semibold text-white drop-shadow-lg truncate">
                  {@media_title}
                </h2>
                <p :if={@content_type == :episode} class="text-xs sm:text-sm text-white/60">
                  {@episode_subtitle}
                </p>
                <p
                  :if={@content_type in [:live, :live_channel]}
                  class="text-xs sm:text-sm text-white/50"
                >
                  Programação ao vivo
                </p>
              </div>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <.fit_button />
              <.lock_button />
            </div>
          </div>
        </div>

        <%!-- Middle: on touch layouts Netflix puts back / play / forward here;
             elsewhere the space stays clear so a click lands on the video. --%>
        <div class="flex flex-1 items-center justify-center pointer-events-none">
          <.center_controls :if={@vod?} disabled={@party_transport_locked} />
        </div>

        <%!-- Bottom bar --%>
        <div
          id="player-bottom-controls"
          class="player-safe-bottom bg-gradient-to-t from-black/80 via-black/40 to-transparent transition-opacity"
        >
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
              <.seek_button
                :if={@vod?}
                direction={:backward}
                disabled={@party_transport_locked}
                class="max-sm:hidden"
              />
              <.seek_button
                :if={@vod?}
                direction={:forward}
                disabled={@party_transport_locked}
                class="max-sm:hidden"
              />
              <.volume_control />
              <.live_badge :if={@content_type in [:live, :live_channel]} />
            </div>

            <.time_display :if={@vod?} />

            <%!-- Centre, larger screens: what is playing, as Netflix shows it --%>
            <div
              id="player-bottom-title"
              class="hidden min-w-0 flex-1 truncate px-4 text-center text-sm text-white/90 sm:block lg:text-base"
            >
              <span class="font-semibold text-white">{@media_title}</span>
              <span :if={@content_type == :episode && @episode_subtitle} class="ml-2 text-white/70">
                {@episode_subtitle}
              </span>
            </div>

            <%!-- Right --%>
            <div class="ml-auto flex items-center gap-1 sm:ml-0 sm:gap-2">
              <.next_episode_button :if={@next_episode} />
              <.episodes_button :if={@season_episodes != []} />
              <.speed_button
                :if={@content_type not in [:live, :live_channel]}
                disabled={@party_transport_locked}
              />
              <.tracks_button subtitle_offset_ms={@subtitle_offset_ms} />
              <.settings_button subtitle_offset_ms={@subtitle_offset_ms} />
              <.pip_button />
              <.fullscreen_button />
            </div>
          </div>
        </div>
      </div>

      <%!-- Pause screen: after a while paused, Netflix dims the picture and
           reminds you what you are watching. JS sets
           data-player-idle-paused on the root; CSS shows this. --%>
      <div
        id="player-pause-info"
        class="pointer-events-none absolute inset-0 z-20 flex items-center bg-gradient-to-r from-black/85 via-black/55 to-transparent px-6 sm:px-16"
        aria-hidden="true"
      >
        <div class="max-w-xl space-y-3">
          <p class="text-sm font-medium text-white/70 sm:text-base">Você está assistindo</p>
          <h2 class="text-3xl font-bold leading-tight text-white sm:text-5xl">{@media_title}</h2>
          <p
            :if={@content_type == :episode && @episode_subtitle}
            class="text-lg font-semibold text-white/90 sm:text-xl"
          >
            {@episode_subtitle}
          </p>
          <p :if={@synopsis} class="line-clamp-4 text-sm leading-relaxed text-white/80 sm:text-base">
            {@synopsis}
          </p>
          <p class="pt-2 text-xs text-white/60 sm:text-sm">Pausado</p>
        </div>
      </div>

      <%!-- Screen lock (touch): everything else is hidden until unlocked --%>
      <div
        id="player-lock-overlay"
        class="absolute inset-x-0 top-[max(1.5rem,env(safe-area-inset-top))] z-50 flex justify-center"
      >
        <button
          type="button"
          id="player-unlock-btn"
          data-player-action="unlock"
          class="flex min-h-12 items-center gap-2 rounded-full bg-black/70 px-5 text-sm font-medium text-white shadow-xl backdrop-blur-md active:scale-95"
        >
          <.icon name="hero-lock-closed" class="size-5" aria-hidden="true" />
          <span>Tela travada · toque para destravar</span>
        </button>
      </div>

      <%!-- Episodes panel (Netflix "Episódios"): the current season, with
           the user's progress; each item opens that episode. --%>
      <div :if={@season_episodes != []} id="player-episodes-layer" class="absolute inset-0 z-40">
        <div class="absolute inset-0 bg-black/50" data-player-action="close-panel" aria-hidden="true" />
        <aside
          id="player-episodes-panel"
          role="dialog"
          aria-modal="true"
          aria-labelledby="player-episodes-title"
          class="absolute inset-y-0 right-0 flex w-full max-w-md flex-col bg-neutral-950/95 shadow-2xl backdrop-blur-md"
        >
          <header class="player-safe-top flex items-center justify-between gap-3 border-b border-white/10 pb-3">
            <h2 id="player-episodes-title" class="text-lg font-bold text-white sm:text-xl">
              Episódios
            </h2>
            <button
              type="button"
              data-player-action="close-panel"
              aria-label="Fechar episódios"
              class="flex size-12 items-center justify-center rounded-full text-white/80 hover:bg-white/10 hover:text-white"
            >
              <.icon name="hero-x-mark" class="size-6" aria-hidden="true" />
            </button>
          </header>
          <ol class="flex-1 space-y-1 overflow-y-auto overscroll-contain p-3">
            <li :for={episode <- @season_episodes}>
              <.link
                navigate={episode.path}
                aria-current={episode.current && "true"}
                class={[
                  "flex gap-3 rounded-lg p-2 transition-colors hover:bg-white/10 focus-visible:outline-2 focus-visible:outline-brand",
                  episode.current && "bg-white/10 ring-1 ring-white/20"
                ]}
              >
                <div class="relative aspect-video w-32 shrink-0 overflow-hidden rounded-md bg-white/10 sm:w-36">
                  <img
                    :if={episode.image}
                    src={ImageProxy.proxy(episode.image)}
                    alt=""
                    class="size-full object-cover"
                    loading="lazy"
                    decoding="async"
                  />
                  <div
                    :if={episode.progress > 0}
                    class="absolute inset-x-0 bottom-0 h-1 bg-white/30"
                    aria-hidden="true"
                  >
                    <div class="h-full bg-brand" style={"width: #{round(episode.progress * 100)}%"} />
                  </div>
                </div>
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-semibold text-white">
                    <span class="text-white/60">{episode.number}.</span> {episode.title}
                  </p>
                  <p :if={episode.current} class="text-xs font-medium text-brand">Assistindo agora</p>
                  <p :if={episode.plot} class="mt-1 line-clamp-2 text-xs text-white/60">
                    {episode.plot}
                  </p>
                </div>
              </.link>
            </li>
          </ol>
        </aside>
      </div>

      <%!-- Next episode overlay (shows when near end) --%>
      <div
        :if={@next_episode}
        id="next-episode-overlay"
        role="dialog"
        aria-live="polite"
        aria-label="Próximo episódio"
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
              class="flex-1 min-h-11 px-4 py-2.5 sm:py-2 bg-brand hover:bg-brand/80 text-white text-sm font-medium rounded transition-colors touch-manipulation"
            >
              Reproduzir
            </button>
            <button
              type="button"
              id="cancel-next-btn"
              class="min-h-11 px-4 py-2.5 sm:py-2 bg-white/10 hover:bg-white/20 text-white text-sm rounded transition-colors touch-manipulation"
            >
              Assistir créditos
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

  @doc """
  The player's first frame while its source is still being chosen: the
  title's picture, dimmed, the same spinner and stage line the player shows
  while it starts, and a way back. It stands in for `video_player/1` until a
  provider that probes each item has named a URL, so the page never sits
  blank on that decision.
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true
  attr :on_close, :string, default: nil

  def player_startup_screen(assigns) do
    assigns =
      assigns
      |> assign(:poster, poster_url(assigns.content, assigns.content_type))
      |> assign(:media_title, Metadata.title(assigns.content, assigns.content_type))

    ~H"""
    <div
      id="player-startup-screen"
      class="relative h-full w-full overflow-hidden bg-black"
      data-player-stage="connecting"
    >
      <img
        :if={@poster}
        src={@poster}
        alt=""
        aria-hidden="true"
        data-player-startup-cover
        class="absolute inset-0 size-full object-cover blur-lg brightness-40"
      />
      <button
        :if={@on_close}
        id="player-startup-close-btn"
        type="button"
        phx-click={@on_close}
        aria-label="Voltar"
        class="absolute left-3 top-3 z-20 flex size-12 items-center justify-center rounded-full bg-black/35 text-white/90 backdrop-blur-xs transition hover:bg-black/50 hover:text-white active:scale-95 sm:left-5 sm:top-5"
      >
        <.icon name="hero-arrow-left" class="size-7" aria-hidden="true" />
      </button>
      <div
        class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-4 px-6 text-center"
        role="status"
        aria-live="polite"
      >
        <div class="size-12 animate-spin rounded-full border-4 border-white/20 border-t-brand drop-shadow-md sm:size-14" />
        <span data-player-stage-text>Conectando…</span>
        <p class="max-w-md truncate text-sm text-white/60">{@media_title}</p>
      </div>
    </div>
    """
  end

  defp poster_url(content, content_type),
    do: content |> Metadata.poster(content_type) |> ImageProxy.proxy()
end
