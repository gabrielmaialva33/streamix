defmodule StreamixWeb.PlayerComponents do
  @moduledoc """
  Video player UI components for Streamix.
  Netflix-style player with pure Tailwind CSS.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias Phoenix.LiveView.JS

  @doc """
  Renders the main video player with all controls.
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true, values: [:live, :movie, :episode]
  attr :stream_url, :string, required: true
  attr :streaming_mode, :atom, default: :balanced
  attr :fullscreen, :boolean, default: false
  attr :on_close, :string, default: nil
  attr :show_controls, :boolean, default: true

  def video_player(assigns) do
    proxy_url = build_proxy_url(assigns.stream_url)
    content_type_str = if assigns.content_type == :live, do: "live", else: "vod"

    assigns =
      assigns
      |> assign(:proxy_url, proxy_url)
      |> assign(:content_type_str, content_type_str)

    ~H"""
    <div
      id="video-player-container"
      class="relative w-full h-full bg-black group/player"
      phx-hook="VideoPlayer"
      data-stream-url={@stream_url}
      data-proxy-url={@proxy_url}
      data-content-type={@content_type_str}
      data-content-id={@content.id}
      data-streaming-mode={@streaming_mode}
    >
      <%!-- Video element --%>
      <video
        id="video-element"
        class="absolute inset-0 w-full h-full object-contain"
        autoplay
        playsinline
      />

      <%!-- Controls overlay --%>
      <div
        :if={@show_controls}
        id="player-controls"
        class="absolute inset-0 flex flex-col justify-between opacity-0 group-hover/player:opacity-100 transition-opacity duration-300 z-10"
      >
        <%!-- Top bar --%>
        <div class="bg-gradient-to-b from-black/80 via-black/40 to-transparent p-4 sm:p-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <button
                :if={@on_close}
                type="button"
                phx-click={@on_close}
                class="p-2 rounded-full text-white/90 hover:text-white hover:bg-white/10 transition-colors"
              >
                <.icon name="hero-x-mark" class="size-6" />
              </button>
              <div>
                <h2 class="text-lg sm:text-xl font-semibold text-white drop-shadow-lg">
                  {content_title(@content, @content_type)}
                </h2>
                <p :if={@content_type == :episode} class="text-sm text-white/60">
                  {episode_subtitle(@content)}
                </p>
              </div>
            </div>

            <button
              type="button"
              id="pip-btn"
              phx-click={JS.dispatch("player:toggle-pip")}
              class="p-2 rounded-full text-white/90 hover:text-white hover:bg-white/10 transition-colors"
              title="Modo Picture-in-Picture"
            >
              <.icon name="hero-rectangle-stack" class="size-5" />
            </button>
          </div>
        </div>

        <%!-- Bottom bar --%>
        <div class="bg-gradient-to-t from-black/80 via-black/40 to-transparent p-4 sm:p-6">
          <%!-- Progress bar --%>
          <.progress_bar :if={@content_type != :live} />

          <%!-- Controls --%>
          <div class="flex items-center justify-between mt-4">
            <%!-- Left --%>
            <div class="flex items-center gap-2 sm:gap-4">
              <.play_pause_button />
              <.volume_control />
              <.time_display :if={@content_type != :live} />
              <.live_badge :if={@content_type == :live} />
            </div>

            <%!-- Right --%>
            <div class="flex items-center gap-1 sm:gap-2">
              <.speed_button :if={@content_type != :live} />
              <.settings_button />
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
    </div>
    """
  end

  def progress_bar(assigns) do
    ~H"""
    <div
      id="progress-container"
      class="relative h-1 bg-white/30 rounded-full cursor-pointer group/progress hover:h-1.5 transition-all"
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
        <div class="absolute right-0 top-1/2 -translate-y-1/2 w-4 h-4 bg-brand rounded-full shadow-lg scale-0 group-hover/progress:scale-100 transition-transform" />
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
      class="p-2 rounded-full text-white hover:bg-white/10 transition-colors"
    >
      <.icon name="hero-play-solid" class="size-7 play-icon" />
      <.icon name="hero-pause-solid" class="size-7 pause-icon hidden" />
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
        class="p-2 rounded-full text-white hover:bg-white/10 transition-colors"
      >
        <.icon name="hero-speaker-wave" class="size-5 volume-on-icon" />
        <.icon name="hero-speaker-x-mark" class="size-5 volume-off-icon hidden" />
      </button>
      <div class="w-0 overflow-hidden group-hover/volume:w-20 transition-all duration-300">
        <input
          type="range"
          id="volume-slider"
          min="0"
          max="100"
          value="100"
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
    <div id="time-display" class="text-white/90 text-sm font-medium tabular-nums hidden sm:block">
      <span id="current-time">0:00</span>
      <span class="text-white/50 mx-1">/</span>
      <span id="duration">0:00</span>
    </div>
    """
  end

  def live_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 px-3 py-1 bg-red-600 rounded text-white text-xs font-bold uppercase tracking-wide">
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
        class="px-3 py-1.5 rounded text-white/90 hover:text-white hover:bg-white/10 transition-colors text-sm font-medium"
      >
        <span id="speed-label">1x</span>
      </button>
      <div
        id="speed-menu"
        class="absolute bottom-full right-0 mb-2 py-2 bg-neutral-900/95 backdrop-blur-md rounded-lg shadow-2xl hidden min-w-[80px] border border-white/10"
        phx-click-away={JS.hide(to: "#speed-menu")}
      >
        <button
          :for={speed <- ["0.5", "0.75", "1", "1.25", "1.5", "2"]}
          type="button"
          phx-click={
            JS.dispatch("player:set-speed", detail: %{speed: speed}) |> JS.hide(to: "#speed-menu")
          }
          class="block w-full px-4 py-2 text-sm text-white/80 hover:text-white hover:bg-white/10 text-center transition-colors"
        >
          {speed}x
        </button>
      </div>
    </div>
    """
  end

  def settings_button(assigns) do
    ~H"""
    <div class="relative" id="settings-container">
      <button
        type="button"
        id="settings-btn"
        phx-click={JS.toggle(to: "#settings-menu") |> JS.hide(to: "#speed-menu")}
        class="p-2 rounded-full text-white/90 hover:text-white hover:bg-white/10 transition-colors"
      >
        <.icon name="hero-cog-6-tooth" class="size-5" />
      </button>
      <div
        id="settings-menu"
        class="absolute bottom-full right-0 mb-2 py-2 bg-neutral-900/95 backdrop-blur-md rounded-lg shadow-2xl hidden min-w-[200px] border border-white/10"
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

        <%!-- Audio --%>
        <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-y border-white/10">
          Áudio
        </div>
        <div id="audio-options" class="py-1">
          <div class="px-4 py-2 text-sm text-white/50">Padrão</div>
        </div>

        <%!-- Subtitles --%>
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
      class="p-2 rounded-full text-white/90 hover:text-white hover:bg-white/10 transition-colors"
      title="Tela cheia"
    >
      <.icon name="hero-arrows-pointing-out" class="size-5 expand-icon" />
      <.icon name="hero-arrows-pointing-in" class="size-5 collapse-icon hidden" />
    </button>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp build_proxy_url(stream_url) when is_binary(stream_url) do
    # Use Phoenix stream proxy for HTTP streams (bypasses mixed content blocking)
    # Base64 URL-safe encoding without padding as expected by StreamController
    encoded_url = Base.url_encode64(stream_url, padding: false)
    "/stream/proxy?url=#{encoded_url}"
  end

  defp build_proxy_url(_), do: nil

  defp content_title(content, :live), do: content.name
  defp content_title(content, :live_channel), do: content.name
  defp content_title(content, :movie), do: content.title || content.name

  defp content_title(content, :episode),
    do: content.title || "Episódio #{Map.get(content, :episode_num, "")}"

  defp episode_subtitle(content) do
    season_num = Map.get(content, :season_number) || get_season_number(content) || "?"
    episode_num = Map.get(content, :episode_num, "?")
    "T#{season_num}:E#{episode_num}"
  end

  defp get_season_number(%{season: %{season_number: num}}), do: num
  defp get_season_number(_), do: nil
end
