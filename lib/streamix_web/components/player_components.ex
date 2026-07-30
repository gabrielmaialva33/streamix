defmodule StreamixWeb.PlayerComponents do
  @moduledoc """
  Video player UI components for Streamix.
  Netflix-style player with pure Tailwind CSS.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias StreamixWeb.Helpers.ImageProxy

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

  def video_player(assigns) do
    # Use external nginx proxy for HTTP streams (except GIndex which plays directly)
    proxy_url = build_proxy_url(assigns.stream_url, assigns.content_type)
    content_type_str = if assigns.content_type in [:live, :live_channel], do: "live", else: "vod"
    # Provider type for JS player (gindex/xtream) - used for codec detection
    source_type = assigns.provider_type || Atom.to_string(assigns.content_type)

    # Explicit stream type hint for token-based URLs where extension is not in the URL
    stream_type = stream_type_hint(assigns.content_type, assigns.content, source_type)

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
      |> assign(:media_title, content_title(assigns.content, assigns.content_type))
      |> assign(:media_subtitle, media_subtitle(assigns.content, assigns.content_type))
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
      |> assign(:uhd_hevc, detect_4k_hevc?(assigns.content) |> to_string())

    ~H"""
    <div
      id="video-player-container"
      class="relative w-full h-full bg-black group/player"
      phx-hook="VideoPlayer"
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
    >
      <%!-- Loading indicator --%>
      <div
        id="loading-indicator"
        class="absolute inset-0 flex items-center justify-center bg-black/50 z-20 pointer-events-none"
        aria-hidden="true"
      >
        <div class="flex flex-col items-center gap-4">
          <div class="w-12 h-12 border-4 border-white/20 border-t-brand rounded-full animate-spin" />
          <span class="text-white/80 text-sm">Carregando...</span>
        </div>
      </div>

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
        preload="metadata"
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
                  {content_title(@content, @content_type)}
                </h2>
                <p :if={@content_type == :episode} class="text-xs sm:text-sm text-white/60">
                  {episode_subtitle(@content)}
                </p>
              </div>
            </div>

            <button
              type="button"
              id="pip-btn"
              phx-click={JS.dispatch("player:toggle-pip")}
              aria-label="Modo Picture-in-Picture"
              class="player-secondary-control flex size-12 shrink-0 touch-manipulation items-center justify-center rounded-full text-white/90 transition-all hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
              title="Modo Picture-in-Picture"
            >
              <.icon name="hero-rectangle-stack" class="size-5" aria-hidden="true" />
            </button>
          </div>
        </div>

        <%!-- Bottom bar --%>
        <div
          id="player-bottom-controls"
          class="player-safe-bottom bg-gradient-to-t from-black/80 via-black/40 to-transparent transition-opacity"
        >
          <%!-- Progress bar --%>
          <.progress_bar :if={@content_type not in [:live, :live_channel]} />

          <%!-- Controls --%>
          <div class="flex items-center justify-between mt-4">
            <%!-- Left --%>
            <div class="flex items-center gap-2 sm:gap-4">
              <.play_pause_button />
              <.volume_control />
              <.time_display :if={@content_type not in [:live, :live_channel]} />
              <.live_badge :if={@content_type in [:live, :live_channel]} />
            </div>

            <%!-- Right --%>
            <div class="flex items-center gap-1 sm:gap-2">
              <.speed_button :if={@content_type not in [:live, :live_channel]} />
              <.settings_button subtitle_offset_ms={@subtitle_offset_ms} />
              <.fullscreen_button />
            </div>
          </div>
        </div>
      </div>

      <%!-- Center play button --%>
      <div
        id="center-play"
        class="absolute inset-0 flex items-center justify-center pointer-events-none opacity-0 transition-opacity"
      >
        <div class="p-5 rounded-full bg-black/40 backdrop-blur-sm">
          <.icon name="hero-play-solid" class="size-16 text-white" />
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

  defp stream_type_hint(content_type, _content, _source_type)
       when content_type in [:live, :live_channel],
       do: "ts"

  defp stream_type_hint(:torrent, _content, _source_type), do: "mp4"

  defp stream_type_hint(_content_type, content, source_type)
       when source_type in [:gindex, "gindex"] do
    extension_from_path(Map.get(content, :gindex_path)) ||
      extension_from_path(Map.get(content, :container_extension)) ||
      "mkv"
  end

  defp stream_type_hint(content_type, content, _source_type)
       when content_type in [:movie, :episode] do
    extension_from_path(Map.get(content, :container_extension)) || "mp4"
  end

  defp stream_type_hint(_content_type, _content, _source_type), do: nil

  defp extension_from_path(value) when is_binary(value) and value != "" do
    value
    |> URI.decode()
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> nil
      ext -> ext
    end
  end

  defp extension_from_path(_value), do: nil

  attr :content, :map, required: true
  attr :status_url, :string, required: true
  attr :peer_target, :integer, default: 30
  attr :on_close, :string, default: nil

  def torrent_swarm_gate(assigns) do
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
            {content_title(@content, :torrent)}
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

  def progress_bar(assigns) do
    ~H"""
    <%!-- Larger touch target wrapper for mobile --%>
    <div class="py-2 -my-2">
      <div
        id="progress-container"
        class="relative h-1.5 sm:h-1 bg-white/30 rounded-full cursor-pointer group/progress active:h-2 sm:hover:h-1.5 transition-all touch-none"
        phx-hook="ProgressBar"
      >
        <div
          id="progress-buffered"
          class="absolute inset-y-0 left-0 bg-white/30 rounded-full pointer-events-none"
          style="width: 0%"
        />
        <div
          id="progress-played"
          class="absolute inset-y-0 left-0 bg-brand rounded-full pointer-events-none"
          style="width: 0%"
        >
          <div class="absolute right-0 top-1/2 -translate-y-1/2 w-5 h-5 sm:w-4 sm:h-4 bg-brand rounded-full shadow-lg scale-100 sm:scale-0 sm:group-hover/progress:scale-100 transition-transform" />
        </div>
      </div>
    </div>
    """
  end

  def play_pause_button(assigns) do
    ~H"""
    <button
      type="button"
      id="play-pause-btn"
      phx-click={JS.dispatch("player:toggle-play")}
      aria-label="Reproduzir ou pausar"
      class="flex size-12 touch-manipulation items-center justify-center rounded-full text-white transition-colors hover:bg-white/10 active:bg-white/20 sm:size-11"
    >
      <.icon name="hero-play-solid" class="size-8 sm:size-7 play-icon" aria-hidden="true" />
      <.icon name="hero-pause-solid" class="size-8 sm:size-7 pause-icon hidden" aria-hidden="true" />
    </button>
    """
  end

  def volume_control(assigns) do
    ~H"""
    <div class="flex items-center gap-2 group/volume">
      <button
        type="button"
        id="mute-btn"
        phx-click={JS.dispatch("player:toggle-mute")}
        aria-label="Ativar ou desativar som"
        aria-pressed="false"
        class="flex size-12 touch-manipulation items-center justify-center rounded-full text-white transition-colors hover:bg-white/10 active:bg-white/20 sm:size-11"
      >
        <.icon name="hero-speaker-wave" class="size-6 sm:size-5 volume-on-icon" aria-hidden="true" />
        <.icon
          name="hero-speaker-x-mark"
          class="size-6 sm:size-5 volume-off-icon hidden"
          aria-hidden="true"
        />
      </button>
      <%!-- Volume slider hidden on mobile, shown on hover for desktop --%>
      <div class="hidden sm:block w-0 overflow-hidden group-hover/volume:w-20 transition-all duration-300">
        <input
          type="range"
          id="volume-slider"
          min="0"
          max="100"
          value="100"
          aria-label="Volume"
          class="w-20 h-1 bg-white/30 rounded-full appearance-none cursor-pointer accent-brand
                 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:w-3 [&::-webkit-slider-thumb]:h-3
                 [&::-webkit-slider-thumb]:bg-white [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:cursor-pointer
                 [&::-moz-range-thumb]:w-3 [&::-moz-range-thumb]:h-3 [&::-moz-range-thumb]:bg-white
                 [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:border-0"
        />
      </div>
    </div>
    """
  end

  def time_display(assigns) do
    ~H"""
    <div
      id="time-display"
      class="hidden text-xs font-medium tabular-nums text-white/90 min-[360px]:block sm:text-sm"
    >
      <span id="current-time">0:00</span>
      <span class="text-white/50 mx-0.5 sm:mx-1">/</span>
      <span id="duration">0:00</span>
    </div>
    """
  end

  def live_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 px-3 py-1 bg-brand rounded text-white text-xs font-bold uppercase tracking-wide">
      <span class="w-2 h-2 bg-white rounded-full animate-pulse" /> Ao Vivo
    </div>
    """
  end

  def speed_button(assigns) do
    ~H"""
    <div class="relative" id="speed-container">
      <button
        type="button"
        id="speed-btn"
        phx-click={JS.toggle(to: "#speed-menu") |> JS.hide(to: "#settings-menu")}
        aria-label="Velocidade de reproducao"
        aria-haspopup="menu"
        aria-expanded="false"
        class="flex size-12 touch-manipulation items-center justify-center rounded text-sm font-medium text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
      >
        <span id="speed-label">1x</span>
      </button>
      <div
        id="speed-menu"
        role="menu"
        aria-label="Opcoes de velocidade"
        class="absolute bottom-full right-0 mb-2 py-2 bg-neutral-900/95 backdrop-blur-md rounded-lg shadow-2xl hidden min-w-[100px] sm:min-w-[80px] border border-white/10"
        phx-click-away={JS.hide(to: "#speed-menu")}
      >
        <button
          :for={speed <- ["0.5", "0.75", "1", "1.25", "1.5", "2"]}
          type="button"
          role="menuitem"
          phx-click={
            JS.dispatch("player:set-speed", detail: %{speed: speed}) |> JS.hide(to: "#speed-menu")
          }
          class="block w-full px-4 py-3 sm:py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 active:bg-white/20 text-center transition-colors touch-manipulation"
        >
          {speed}x
        </button>
      </div>
    </div>
    """
  end

  attr :subtitle_offset_ms, :integer, default: 0

  def settings_button(assigns) do
    ~H"""
    <div class="relative" id="settings-container">
      <button
        type="button"
        id="settings-btn"
        phx-click={JS.toggle(to: "#settings-menu") |> JS.hide(to: "#speed-menu")}
        aria-label="Configuracoes"
        aria-haspopup="menu"
        aria-expanded="false"
        class="flex size-12 touch-manipulation items-center justify-center rounded-full text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
      >
        <.icon name="hero-cog-6-tooth" class="size-6 sm:size-5" aria-hidden="true" />
      </button>
      <div
        id="settings-menu"
        class="absolute bottom-full right-0 mb-2 py-2 bg-neutral-900/95 backdrop-blur-md rounded-lg shadow-2xl hidden min-w-[280px] border border-white/10 max-h-[60vh] overflow-y-auto"
        phx-click-away={JS.hide(to: "#settings-menu")}
      >
        <%!-- Quality --%>
        <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-b border-white/10">
          Qualidade
        </div>
        <div id="quality-options" class="py-1">
          <button
            type="button"
            phx-click={JS.push("set_quality", value: %{level: -1})}
            class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors"
          >
            <span>Automático</span>
            <span class="size-4 quality-check" data-level="-1">
              <.icon name="hero-check" class="size-4" />
            </span>
          </button>
        </div>

        <%!-- Audio Section - hidden until tracks detected --%>
        <div id="audio-section" class="hidden">
          <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-y border-white/10">
            Áudio
          </div>
          <div id="audio-options" class="py-1">
            <div class="px-4 py-2 text-sm text-white/50">Padrão</div>
          </div>
        </div>

        <%!-- Subtitles Section - hidden until tracks detected --%>
        <div id="subtitle-section" class="hidden">
          <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-y border-white/10">
            Legendas
          </div>
          <div id="subtitle-options" class="py-1">
            <button
              type="button"
              phx-click={JS.push("set_subtitle_track", value: %{track: -1})}
              class="flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors"
            >
              <span>Desativadas</span>
              <span class="size-4 subtitle-check" data-track="-1">
                <.icon name="hero-check" class="size-4" />
              </span>
            </button>
          </div>
          <div id="subtitle-sync-controls" class="border-t border-white/10 px-4 py-3">
            <div class="flex items-center justify-between gap-3">
              <span class="text-xs font-semibold uppercase tracking-wider text-white/50">
                Sincronismo
              </span>
              <span id="subtitle-sync-value" class="text-sm font-medium tabular-nums text-white">
                {format_subtitle_offset(@subtitle_offset_ms)}
              </span>
            </div>
            <p class="mt-1 text-xs text-white/45">− adianta · + atrasa</p>
            <div class="mt-2 grid grid-cols-5 gap-1">
              <button
                :for={
                  {label, delta} <- [{"−1s", -1000}, {"−0,5", -500}, {"+0,5", 500}, {"+1s", 1000}]
                }
                type="button"
                phx-click="adjust_subtitle_offset"
                phx-value-delta={delta}
                aria-label={"Ajustar legenda em #{label}"}
                class="min-h-10 touch-manipulation rounded-md bg-white/5 px-1 text-xs font-medium text-white/80 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20"
              >
                {label}
              </button>
              <button
                type="button"
                phx-click="reset_subtitle_offset"
                class="min-h-10 touch-manipulation rounded-md bg-white/5 px-1 text-xs font-medium text-white/60 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20"
              >
                Zerar
              </button>
            </div>
          </div>
        </div>

        <%!-- Aspect ratio. Pure-client choice; no LiveView round-trip
             so the change feels instant. The hook persists the pick to
             localStorage so it sticks across reloads. --%>
        <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-y border-white/10">
          Proporção
        </div>
        <div id="aspect-options" class="py-1">
          <%= for {label, mode} <- [
                {"Automático", "auto"},
                {"Preencher tela", "cover"},
                {"16:9", "16-9"},
                {"4:3", "4-3"},
                {"Nativo", "native"}
              ] do %>
            <button
              type="button"
              data-aspect-mode={mode}
              class="aspect-option flex items-center justify-between w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 transition-colors"
            >
              <span>{label}</span>
              <span class="size-4 aspect-check hidden" data-aspect-check={mode}>
                <.icon name="hero-check" class="size-4" />
              </span>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def fullscreen_button(assigns) do
    ~H"""
    <button
      type="button"
      id="fullscreen-btn"
      phx-click={JS.dispatch("player:toggle-fullscreen")}
      aria-label="Tela cheia"
      class="flex size-12 touch-manipulation items-center justify-center rounded-full text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
      title="Tela cheia"
    >
      <.icon name="hero-arrows-pointing-out" class="size-6 sm:size-5 expand-icon" aria-hidden="true" />
      <.icon
        name="hero-arrows-pointing-in"
        class="size-6 sm:size-5 collapse-icon hidden"
        aria-hidden="true"
      />
    </button>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp format_subtitle_offset(0), do: "0s"

  defp format_subtitle_offset(offset_ms) do
    seconds = offset_ms / 1_000
    sign = if seconds > 0, do: "+", else: ""
    precision = if rem(offset_ms, 1_000) == 0, do: 0, else: 1
    "#{sign}#{:erlang.float_to_binary(seconds, decimals: precision)}s"
  end

  # Token-based URLs (already proxied through /api/stream/proxy?token=) — pass through as-is
  # These never contain credentials and are already ready for the player
  defp build_proxy_url(stream_url, _content_type) when is_binary(stream_url) do
    if String.contains?(stream_url, "/api/stream/proxy?token=") or
         String.contains?(stream_url, "/api/stream/torrent/") do
      stream_url
    else
      # Fallback for any non-token URLs (e.g., direct external URLs)
      proxy_base =
        Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

      "#{proxy_base}/proxy?url=#{URI.encode_www_form(stream_url)}"
    end
  end

  defp build_proxy_url(_, _), do: nil

  defp content_title(content, :live), do: content.name
  defp content_title(content, :live_channel), do: content.name
  defp content_title(content, :movie), do: content.title || content.name
  defp content_title(content, :gindex), do: content.title || content.name
  defp content_title(content, :torrent), do: content.title || content.name

  defp content_title(content, :episode),
    do: content.title || "Episódio #{Map.get(content, :episode_num, "")}"

  defp content_title(content, :gindex_episode),
    do: content.title || content.name || "Episódio #{Map.get(content, :episode_num, "")}"

  defp episode_subtitle(content) do
    season_num = Map.get(content, :season_number) || get_season_number(content) || "?"
    episode_num = Map.get(content, :episode_num, "?")
    "T#{season_num}:E#{episode_num}"
  end

  defp media_subtitle(content, type) when type in [:episode, :gindex_episode] do
    series_name =
      Map.get(content, :series_name) ||
        direct_series_name(content) ||
        season_series_name(content)

    [series_name, episode_subtitle(content)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  defp media_subtitle(_content, type) when type in [:live, :live_channel], do: "Ao vivo"
  defp media_subtitle(_content, _type), do: "Streamix"

  defp direct_series_name(%{series: %{name: name}}) when is_binary(name), do: name
  defp direct_series_name(_), do: nil

  defp season_series_name(%{season: %{series: %{name: name}}}) when is_binary(name), do: name
  defp season_series_name(_), do: nil

  defp get_season_number(%{season: %{season_number: num}}), do: num
  defp get_season_number(_), do: nil

  # Heuristic 4K-HEVC detector — operates on the strings the upstream
  # release/file naming actually carries (`Matrix.1999.2160p.HMAX...HEVC.Dual-C76.mkv`,
  # `/1:/Filmes/Filmes 4k (227)/...`). The hook uses this to flip on
  # the avbridge engine only for heavy content; everything else stays
  # on the cheap AVPlayer path.
  @fourk_hevc_pattern ~r/(2160p|\b4k\b|uhd|hevc|x265|h265|hvc1|hev1)/i

  defp detect_4k_hevc?(content) when is_map(content) do
    haystack =
      [
        Map.get(content, :gindex_path),
        Map.get(content, :title),
        Map.get(content, :name)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    haystack != "" and Regex.match?(@fourk_hevc_pattern, haystack)
  end
end
