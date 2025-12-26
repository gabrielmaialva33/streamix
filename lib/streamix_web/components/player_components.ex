defmodule StreamixWeb.PlayerComponents do
  @moduledoc """
  Video player UI components for Streamix.

  Provides a unified video player supporting:
  - Multiple streaming formats (HLS, MPEG-TS, MP4, FLV)
  - Adaptive streaming with quality selection
  - Audio/subtitle track selection
  - Picture-in-Picture support
  - Custom controls with Tailwind CSS styling
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias Phoenix.LiveView.JS

  @doc """
  Renders the main video player with all controls.

  ## Attributes

    * `:content` - The content being played (channel, movie, or episode)
    * `:content_type` - Type of content: :live, :movie, or :episode
    * `:stream_url` - Direct stream URL
    * `:streaming_mode` - Initial streaming mode (:low_latency, :balanced, :quality)
    * `:fullscreen` - Whether to render in fullscreen mode
    * `:on_close` - Event name to trigger when closing the player
    * `:show_controls` - Whether to show player controls

  ## Examples

      <.video_player
        content={@channel}
        content_type={:live}
        stream_url={@stream_url}
      />
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true, values: [:live, :movie, :episode]
  attr :stream_url, :string, required: true
  attr :streaming_mode, :atom, default: :balanced, values: [:low_latency, :balanced, :quality]
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
      class={[
        "relative bg-black group",
        @fullscreen && "fixed inset-0 z-50",
        !@fullscreen && "w-full aspect-video rounded-lg overflow-hidden"
      ]}
      phx-hook="VideoPlayer"
      data-stream-url={@stream_url}
      data-proxy-url={@proxy_url}
      data-content-type={@content_type_str}
      data-content-id={@content.id}
      data-streaming-mode={@streaming_mode}
    >
      <video
        id="video-element"
        class="w-full h-full object-contain"
        autoplay
        playsinline
      />

      <.player_overlay
        :if={@show_controls}
        content={@content}
        content_type={@content_type}
        on_close={@on_close}
      />
    </div>
    """
  end

  @doc """
  Renders the player overlay with controls.
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true
  attr :on_close, :string, default: nil

  def player_overlay(assigns) do
    ~H"""
    <div
      id="player-overlay"
      class="absolute inset-0 flex flex-col justify-between opacity-0 group-hover:opacity-100 focus-within:opacity-100 transition-opacity duration-300"
    >
      <.player_top_bar content={@content} content_type={@content_type} on_close={@on_close} />
      <.player_bottom_bar content_type={@content_type} />
    </div>
    """
  end

  @doc """
  Renders the top bar with title and feature buttons.
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true
  attr :on_close, :string, default: nil

  def player_top_bar(assigns) do
    ~H"""
    <div class="bg-gradient-to-b from-black/80 to-transparent p-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-4">
          <button
            :if={@on_close}
            type="button"
            phx-click={@on_close}
            class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
          <div class="text-white">
            <h2 class="text-lg font-semibold">{content_title(@content, @content_type)}</h2>
            <p :if={@content_type == :episode} class="text-sm text-white/70">
              {episode_subtitle(@content)}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.pip_button />
          <.cast_button />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the bottom control bar.
  """
  attr :content_type, :atom, required: true

  def player_bottom_bar(assigns) do
    ~H"""
    <div class="bg-gradient-to-t from-black/80 to-transparent p-4">
      <.progress_bar :if={@content_type != :live} />

      <div class="flex items-center justify-between mt-3">
        <div class="flex items-center gap-3">
          <.play_pause_button />
          <.volume_control />
          <.time_display :if={@content_type != :live} />
          <.live_badge :if={@content_type == :live} />
        </div>

        <div class="flex items-center gap-2">
          <.playback_speed :if={@content_type != :live} />
          <.quality_selector />
          <.audio_selector />
          <.subtitle_selector />
          <.fullscreen_button />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the progress bar for VOD content.
  """
  def progress_bar(assigns) do
    ~H"""
    <div
      id="progress-container"
      class="group/progress relative h-1 bg-white/30 rounded-full cursor-pointer hover:h-2 transition-all"
      phx-hook="ProgressBar"
    >
      <div
        id="progress-buffered"
        class="absolute inset-y-0 left-0 bg-white/50 rounded-full"
        style="width: 0%"
      />
      <div
        id="progress-played"
        class="absolute inset-y-0 left-0 bg-primary rounded-full"
        style="width: 0%"
      >
        <div class="absolute right-0 top-1/2 -translate-y-1/2 w-3 h-3 bg-primary rounded-full opacity-0 group-hover/progress:opacity-100 transition-opacity" />
      </div>
    </div>
    """
  end

  @doc """
  Renders the play/pause button.
  """
  def play_pause_button(assigns) do
    ~H"""
    <button
      type="button"
      id="play-pause-btn"
      phx-click={JS.dispatch("player:toggle-play")}
      class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20"
    >
      <.icon name="hero-play-solid" class="size-5 play-icon" />
      <.icon name="hero-pause-solid" class="size-5 pause-icon hidden" />
    </button>
    """
  end

  @doc """
  Renders the volume control.
  """
  def volume_control(assigns) do
    ~H"""
    <div class="flex items-center gap-2 group/volume">
      <button
        type="button"
        id="mute-btn"
        phx-click={JS.dispatch("player:toggle-mute")}
        class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20"
      >
        <.icon name="hero-speaker-wave" class="size-5 volume-on-icon" />
        <.icon name="hero-speaker-x-mark" class="size-5 volume-off-icon hidden" />
      </button>
      <input
        type="range"
        id="volume-slider"
        min="0"
        max="100"
        value="100"
        class="w-0 group-hover/volume:w-20 transition-all duration-200 range range-xs range-primary"
      />
    </div>
    """
  end

  @doc """
  Renders the time display for VOD content.
  """
  def time_display(assigns) do
    ~H"""
    <div id="time-display" class="text-white text-sm font-mono">
      <span id="current-time">0:00</span>
      <span class="text-white/50"> / </span>
      <span id="duration">0:00</span>
    </div>
    """
  end

  @doc """
  Renders the live badge for live content.
  """
  def live_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 px-2 py-1 bg-error rounded text-white text-xs font-semibold uppercase">
      <span class="w-2 h-2 bg-white rounded-full animate-pulse" />
      <span>Ao Vivo</span>
    </div>
    """
  end

  @doc """
  Renders the playback speed selector for VOD content.
  """
  def playback_speed(assigns) do
    ~H"""
    <div class="dropdown dropdown-top dropdown-end">
      <button
        type="button"
        tabindex="0"
        class="btn btn-ghost btn-sm text-white hover:bg-white/20 gap-1"
      >
        <span id="speed-label">1x</span>
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm bg-base-200 rounded-box w-24 p-2 shadow-lg mb-2"
      >
        <li :for={speed <- ["0.5", "0.75", "1", "1.25", "1.5", "2"]}>
          <button
            type="button"
            phx-click={JS.dispatch("player:set-speed", detail: %{speed: speed})}
            class="text-sm"
          >
            {speed}x
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the quality selector dropdown.
  """
  def quality_selector(assigns) do
    ~H"""
    <div class="dropdown dropdown-top dropdown-end">
      <button
        type="button"
        tabindex="0"
        id="quality-btn"
        class="btn btn-ghost btn-sm text-white hover:bg-white/20 gap-1"
      >
        <.icon name="hero-cog-6-tooth" class="size-4" />
        <span id="quality-label" class="hidden sm:inline">Auto</span>
      </button>
      <ul
        tabindex="0"
        id="quality-menu"
        class="dropdown-content menu menu-sm bg-base-200 rounded-box w-32 p-2 shadow-lg mb-2"
      >
        <li class="menu-title text-xs">Qualidade</li>
        <li>
          <button
            type="button"
            phx-click={JS.push("set_quality", value: %{level: -1})}
            class="text-sm quality-option"
            data-level="-1"
          >
            Auto
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the audio track selector dropdown.
  """
  def audio_selector(assigns) do
    ~H"""
    <div class="dropdown dropdown-top dropdown-end" id="audio-selector-container">
      <button
        type="button"
        tabindex="0"
        id="audio-btn"
        class="btn btn-ghost btn-sm text-white hover:bg-white/20"
      >
        <.icon name="hero-speaker-wave" class="size-4" />
      </button>
      <ul
        tabindex="0"
        id="audio-menu"
        class="dropdown-content menu menu-sm bg-base-200 rounded-box w-40 p-2 shadow-lg mb-2"
      >
        <li class="menu-title text-xs">Áudio</li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the subtitle track selector dropdown.
  """
  def subtitle_selector(assigns) do
    ~H"""
    <div class="dropdown dropdown-top dropdown-end" id="subtitle-selector-container">
      <button
        type="button"
        tabindex="0"
        id="subtitle-btn"
        class="btn btn-ghost btn-sm text-white hover:bg-white/20"
      >
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
      </button>
      <ul
        tabindex="0"
        id="subtitle-menu"
        class="dropdown-content menu menu-sm bg-base-200 rounded-box w-40 p-2 shadow-lg mb-2"
      >
        <li class="menu-title text-xs">Legendas</li>
        <li>
          <button
            type="button"
            phx-click={JS.push("set_subtitle_track", value: %{track: -1})}
            class="text-sm subtitle-option"
            data-track="-1"
          >
            Desativadas
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the Picture-in-Picture button.
  """
  def pip_button(assigns) do
    ~H"""
    <button
      type="button"
      id="pip-btn"
      phx-click={JS.push("toggle_pip")}
      class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20"
      title="Picture-in-Picture"
    >
      <.icon name="hero-arrows-pointing-out" class="size-5" />
    </button>
    """
  end

  @doc """
  Renders the Chromecast/AirPlay button.
  """
  def cast_button(assigns) do
    ~H"""
    <button
      type="button"
      id="cast-btn"
      class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20 hidden"
      title="Cast"
    >
      <svg class="size-5" viewBox="0 0 24 24" fill="currentColor">
        <path d="M1 18v3h3c0-1.66-1.34-3-3-3zm0-4v2c2.76 0 5 2.24 5 5h2c0-3.87-3.13-7-7-7zm0-4v2c4.97 0 9 4.03 9 9h2c0-6.08-4.93-11-11-11zm20-7H3c-1.1 0-2 .9-2 2v3h2V5h18v14h-7v2h7c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2z" />
      </svg>
    </button>
    """
  end

  @doc """
  Renders the fullscreen toggle button.
  """
  def fullscreen_button(assigns) do
    ~H"""
    <button
      type="button"
      id="fullscreen-btn"
      phx-click={JS.dispatch("player:toggle-fullscreen")}
      class="btn btn-circle btn-ghost btn-sm text-white hover:bg-white/20"
      title="Tela cheia"
    >
      <.icon name="hero-arrows-pointing-out" class="size-5 expand-icon" />
      <.icon name="hero-arrows-pointing-in" class="size-5 collapse-icon hidden" />
    </button>
    """
  end

  @doc """
  Renders a compact player card for use in lists.
  """
  attr :content, :map, required: true
  attr :content_type, :atom, required: true
  attr :thumbnail, :string, default: nil
  attr :on_play, :string, default: "play"

  def player_card(assigns) do
    ~H"""
    <div class="card bg-base-200 hover:bg-base-300 transition-all group cursor-pointer">
      <figure
        class="relative aspect-video bg-base-300"
        phx-click={@on_play}
        phx-value-id={@content.id}
      >
        <img
          :if={@thumbnail}
          src={@thumbnail}
          alt={content_title(@content, @content_type)}
          class="w-full h-full object-cover"
          loading="lazy"
        />
        <div
          :if={!@thumbnail}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-tv" class="size-12" />
        </div>

        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <div class="btn btn-circle btn-lg btn-primary">
            <.icon name="hero-play-solid" class="size-8" />
          </div>
        </div>

        <.live_badge :if={@content_type == :live} />
      </figure>

      <div class="card-body p-3">
        <h3 class="font-medium text-sm truncate">{content_title(@content, @content_type)}</h3>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp build_proxy_url(stream_url) when is_binary(stream_url) do
    encoded = Base.url_encode64(stream_url, padding: false)
    "/api/stream/proxy?url=#{encoded}"
  end

  defp build_proxy_url(_), do: nil

  defp content_title(content, :live), do: content.name
  defp content_title(content, :movie), do: content.title || content.name

  defp content_title(content, :episode),
    do: content.title || "Episode #{Map.get(content, :episode_num, "")}"

  defp episode_subtitle(content) do
    season_num = get_in(content, [:season, :season_number]) || content[:season_number] || "?"
    episode_num = content[:episode_num] || "?"
    "S#{season_num}:E#{episode_num}"
  end
end
