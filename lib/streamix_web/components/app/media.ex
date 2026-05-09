defmodule StreamixWeb.App.Media do
  @moduledoc """
  Provider, live-channel, and inline video-player components.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias Streamix.Iptv.LiveChannel
  alias StreamixWeb.Helpers.ImageProxy

  attr :channel, :map, required: true
  attr :current_program, :any, default: nil
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :show_epg, :boolean, default: true
  attr :on_favorite, :string, default: "toggle_favorite"

  def live_channel_card(assigns) do
    ~H"""
    <div class="group relative">
      <.link
        navigate={~p"/watch/live_channel/#{@channel.id}"}
        class="block rounded-xl overflow-hidden bg-surface-elevated border border-glass-border hover:border-brand/30 transition-all card-glow hover:-translate-y-1 cursor-pointer"
      >
        <div class="relative aspect-video bg-gradient-to-br from-zinc-800/80 to-zinc-900/80 flex items-center justify-center p-4 sm:p-6">
          <div
            id={"channel-img-#{@channel.id}"}
            phx-hook="ImageFallback"
            class="w-full h-full flex items-center justify-center"
          >
            <img
              :if={@channel.stream_icon not in [nil, ""]}
              src={ImageProxy.proxy(@channel.stream_icon)}
              alt={@channel.name}
              class="max-w-full max-h-full object-contain drop-shadow-lg"
              loading="lazy"
              data-fallback-target
            />
            <div
              data-fallback
              class={[
                "flex flex-col items-center justify-center text-center",
                @channel.stream_icon not in [nil, ""] && "hidden"
              ]}
            >
              <.icon name="hero-tv" class="size-6 sm:size-10 text-text-muted/40 mb-1" />
              <span class="text-[9px] sm:text-xs text-text-muted leading-tight line-clamp-2">
                {@channel.name}
              </span>
            </div>
          </div>

          <span class="absolute top-2 left-2 flex items-center gap-1 px-1.5 py-0.5 text-[9px] sm:text-[10px] font-bold rounded-md bg-brand/90 text-white backdrop-blur-sm">
            <span class="w-1.5 h-1.5 rounded-full bg-white live-pulse" /> AO VIVO
          </span>

          <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
            <div class="w-12 h-12 rounded-full bg-white/90 flex items-center justify-center shadow-lg">
              <.icon name="hero-play-solid" class="size-6 text-black ml-0.5" />
            </div>
          </div>
        </div>

        <div class="px-3 py-2.5 space-y-1">
          <h3
            class="font-medium text-xs sm:text-sm text-text-primary truncate group-hover:text-brand transition-colors"
            title={@channel.name}
          >
            {@channel.name}
          </h3>
          <StreamixWeb.EpgComponents.epg_now
            :if={@show_epg}
            current_program={@current_program || Map.get(@channel, :current_program)}
            compact={true}
          />
        </div>
      </.link>

      <button
        :if={@show_favorite}
        type="button"
        phx-click={@on_favorite}
        phx-value-id={@channel.id}
        phx-value-type="live_channel"
        aria-label={if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"}
        class={[
          "absolute top-2 right-2 z-10 p-1.5 rounded-full backdrop-blur-sm transition-all",
          @is_favorite && "text-brand bg-brand/20",
          !@is_favorite &&
            "text-white/60 bg-black/30 opacity-0 group-hover:opacity-100 hover:text-brand hover:bg-brand/20"
        ]}
      >
        <.icon
          name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
          class="size-4"
        />
      </button>
    </div>
    """
  end

  attr :provider, :map, required: true
  attr :on_sync, :string, default: "sync_provider"
  attr :on_edit, :string, default: "edit_provider"
  attr :on_delete, :string, default: "delete_provider"

  def provider_card(assigns) do
    ~H"""
    <div class="rounded-xl bg-surface border border-border p-4 hover:border-brand/30 transition-colors">
      <div class="flex items-start justify-between gap-4 mb-3">
        <div class="min-w-0 flex-1">
          <h3 class="font-semibold text-text-primary truncate">{@provider.name}</h3>
          <p class="text-sm text-text-secondary truncate">{@provider.url}</p>
        </div>
        <.sync_status_badge status={@provider.sync_status} />
      </div>

      <div class="flex flex-wrap items-center gap-4 text-sm text-text-secondary mb-4">
        <div
          :if={@provider.live_channels_count && @provider.live_channels_count > 0}
          class="flex items-center gap-1.5"
        >
          <.icon name="hero-tv" class="size-4" />
          <span>{@provider.live_channels_count} ao vivo</span>
        </div>
        <div
          :if={@provider.movies_count && @provider.movies_count > 0}
          class="flex items-center gap-1.5"
        >
          <.icon name="hero-film" class="size-4" />
          <span>{@provider.movies_count} filmes</span>
        </div>
        <div
          :if={@provider.series_count && @provider.series_count > 0}
          class="flex items-center gap-1.5"
        >
          <.icon name="hero-video-camera" class="size-4" />
          <span>{@provider.series_count} séries</span>
        </div>
        <div :if={@provider.live_synced_at} class="flex items-center gap-1.5">
          <.icon name="hero-clock" class="size-4" />
          <span>{format_relative_time(@provider.live_synced_at)}</span>
        </div>
      </div>

      <div class="flex items-center justify-end gap-2 pt-3 border-t border-border">
        <button
          type="button"
          phx-click={@on_sync}
          phx-value-id={@provider.id}
          disabled={@provider.sync_status in ["pending", "syncing"]}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-lg transition-colors disabled:opacity-50"
        >
          <.icon
            name="hero-arrow-path"
            class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
          /> Sync
        </button>
        <.link
          navigate={~p"/providers/#{@provider.id}"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-md transition-colors"
        >
          <.icon name="hero-eye" class="size-4" /> Ver
        </.link>
        <button
          type="button"
          phx-click={@on_edit}
          phx-value-id={@provider.id}
          class="p-1.5 text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-md transition-colors"
        >
          <.icon name="hero-pencil" class="size-4" />
        </button>
        <button
          type="button"
          phx-click={@on_delete}
          phx-value-id={@provider.id}
          data-confirm="Tem certeza que deseja excluir este provedor?"
          class="p-1.5 text-text-secondary hover:text-error hover:bg-error/10 rounded-md transition-colors"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp sync_status_badge(assigns) do
    {bg, text, label} =
      case assigns.status do
        "idle" -> {"bg-text-muted/10", "text-text-muted", "Inativo"}
        "pending" -> {"bg-warning/10", "text-warning", "Pendente"}
        "syncing" -> {"bg-info/10", "text-info", "Sincronizando"}
        "completed" -> {"bg-success/10", "text-success", "Sincronizado"}
        "failed" -> {"bg-error/10", "text-error", "Falhou"}
        _ -> {"bg-text-muted/10", "text-text-muted", "Desconhecido"}
      end

    assigns = assign(assigns, bg: bg, text: text, label: label)

    ~H"""
    <span class={["inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium", @bg, @text]}>
      {@label}
    </span>
    """
  end

  defp format_relative_time(nil), do: "Nunca"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)}min atrás"
      diff < 86_400 -> "#{div(diff, 3600)}h atrás"
      true -> "#{div(diff, 86_400)}d atrás"
    end
  end

  attr :channel, :map, required: true
  attr :provider, :map, required: true
  attr :on_close, :string, default: "close_player"
  attr :use_proxy, :boolean, default: true

  def video_player_v2(assigns) do
    stream_url = LiveChannel.stream_url(assigns.channel, assigns.provider)

    proxy_url =
      if assigns.use_proxy do
        proxy_base =
          Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

        "#{proxy_base}/proxy?url=#{URI.encode_www_form(stream_url)}"
      end

    assigns = assign(assigns, stream_url: stream_url, proxy_url: proxy_url)

    ~H"""
    <div
      id="video-player-modal"
      class="fixed inset-0 z-50 bg-black/95 flex items-center justify-center"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <button
        type="button"
        phx-click={@on_close}
        class="absolute top-4 right-4 z-10 p-2 rounded-full text-white/70 hover:text-white hover:bg-white/10 transition-colors"
      >
        <.icon name="hero-x-mark" class="size-6" />
      </button>

      <div class="absolute top-4 left-4 z-10 text-white">
        <h2 class="text-lg font-semibold">{@channel.name}</h2>
      </div>

      <div
        id="video-container"
        class="w-full h-full max-w-7xl max-h-[80vh] mx-4"
        phx-hook="VideoPlayer"
        data-stream-url={@stream_url}
        data-proxy-url={@proxy_url}
      >
        <video
          id="video-element"
          class="w-full h-full bg-black rounded-lg"
          controls
          preload="metadata"
          playsinline
        >
        </video>
      </div>
    </div>
    """
  end
end
