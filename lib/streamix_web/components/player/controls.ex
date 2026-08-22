defmodule StreamixWeb.PlayerComponents.Controls do
  @moduledoc false

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  alias Phoenix.LiveView.JS

  def progress_bar(assigns) do
    ~H"""
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
      class="flex size-12 touch-manipulation items-center justify-center rounded-full text-white transition-colors hover:bg-white/10 active:bg-white/25 sm:size-11"
    >
      <.icon name="hero-play-solid" class="play-icon size-8 sm:size-7" aria-hidden="true" />
      <.icon
        name="hero-pause-solid"
        class="pause-icon hidden size-8 sm:size-7"
        aria-hidden="true"
      />
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
        aria-label="Velocidade de reprodução"
        aria-haspopup="menu"
        aria-expanded="false"
        class="flex size-12 touch-manipulation items-center justify-center rounded text-sm font-medium text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 sm:size-11"
      >
        <span id="speed-label">1x</span>
      </button>
      <div
        id="speed-menu"
        role="menu"
        aria-label="Opções de velocidade"
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
        aria-label="Configurações"
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

        <div id="audio-section" class="hidden">
          <div class="px-4 py-2 text-xs text-white/50 font-semibold uppercase tracking-wider border-y border-white/10">
            Áudio
          </div>
          <div id="audio-options" class="py-1">
            <div class="px-4 py-2 text-sm text-white/50">Padrão</div>
          </div>
        </div>

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

  def pip_button(assigns) do
    ~H"""
    <button
      type="button"
      id="pip-btn"
      phx-click={JS.dispatch("player:toggle-pip")}
      aria-label="Ativar picture-in-picture"
      aria-pressed="false"
      disabled
      class="hidden flex size-12 touch-manipulation items-center justify-center rounded-full text-white/90 transition-colors hover:bg-white/10 hover:text-white active:bg-white/20 disabled:pointer-events-none sm:size-11"
      title="Picture-in-picture"
    >
      <.icon name="hero-rectangle-stack" class="size-6 sm:size-5" aria-hidden="true" />
    </button>
    """
  end

  defp format_subtitle_offset(0), do: "0s"

  defp format_subtitle_offset(offset_ms) do
    seconds = offset_ms / 1_000
    sign = if seconds > 0, do: "+", else: ""
    precision = if rem(offset_ms, 1_000) == 0, do: 0, else: 1
    "#{sign}#{:erlang.float_to_binary(seconds, decimals: precision)}s"
  end
end
