defmodule StreamixWeb.App.Media do
  @moduledoc """
  Provider, live-channel, and inline video-player components.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents
  alias StreamixWeb.Helpers.ImageProxy

  @sync_status_badges %{
    "idle" => {"bg-text-muted/10", "text-text-muted", "Inativo"},
    "pending" => {"bg-warning/10", "text-warning", "Pendente"},
    "syncing" => {"bg-info/10", "text-info", "Sincronizando"},
    "paused_quota" => {"bg-warning/10", "text-warning", "Pausado pela cota"},
    "paused_upstream" => {"bg-warning/10", "text-warning", "Origem limitada"},
    "completed" => {"bg-success/10", "text-success", "Sincronizado"},
    "partial" => {"bg-warning/10", "text-warning", "Parcial"},
    "failed" => {"bg-error/10", "text-error", "Falhou"}
  }
  @unknown_sync_badge {"bg-text-muted/10", "text-text-muted", "Desconhecido"}

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
        href={~p"/watch/live_channel/#{@channel.id}"}
        class="block cursor-pointer overflow-hidden rounded-lg border border-glass-border bg-surface transition-all hover:-translate-y-1 hover:border-brand/30 sm:rounded-xl sm:bg-surface-elevated card-glow"
      >
        <div class="relative flex aspect-video items-center justify-center bg-gradient-to-br from-zinc-800/80 to-zinc-900/80 p-2.5 sm:p-6">
          <div
            id={"channel-img-#{@channel.id}"}
            phx-hook="ImageFallback"
            class="w-full h-full flex items-center justify-center"
          >
            <img
              :if={@channel.stream_icon not in [nil, ""]}
              src={ImageProxy.proxy(@channel.stream_icon)}
              alt={@channel.name}
              class="max-h-[72%] max-w-[76%] object-contain drop-shadow-lg sm:max-h-full sm:max-w-full"
              loading="lazy"
              decoding="async"
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
              <span class="text-2xs sm:text-xs text-text-muted leading-tight line-clamp-2">
                {@channel.name}
              </span>
            </div>
          </div>

          <span class="absolute left-1.5 top-1.5 flex items-center gap-1 rounded-md bg-brand/90 px-1.5 py-0.5 text-[9px] font-bold text-white backdrop-blur-sm sm:left-2 sm:top-2 sm:text-2xs">
            <span class="size-1 rounded-full bg-white live-pulse sm:size-1.5" /> AO VIVO
          </span>

          <div class="absolute inset-0 hidden items-center justify-center bg-black/50 opacity-0 transition-opacity group-hover:opacity-100 sm:flex">
            <div class="flex size-11 items-center justify-center rounded-full bg-white/90 shadow-lg sm:size-12">
              <.icon name="hero-play-solid" class="ml-0.5 size-5 text-black sm:size-6" />
            </div>
          </div>
        </div>

        <div class="space-y-0.5 px-2 py-2 sm:space-y-1 sm:px-3 sm:py-2.5">
          <h3
            class="truncate text-[11px] font-medium leading-tight text-text-primary transition-colors group-hover:text-brand sm:text-sm sm:leading-normal"
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
          "absolute right-0.5 top-0.5 z-10 flex size-11 items-center justify-center rounded-full backdrop-blur-sm transition-all sm:right-1 sm:top-1",
          @is_favorite && "bg-brand/20 text-brand",
          !@is_favorite &&
            "bg-black/25 text-white/60 opacity-100 hover:bg-brand/20 hover:text-brand sm:opacity-0 sm:group-hover:opacity-100"
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
  attr :sync_progress, :map, default: nil
  attr :on_sync, :string, default: "sync_provider"
  attr :on_edit, :string, default: "edit_provider"
  attr :on_delete, :string, default: "delete_provider"

  def provider_card(assigns) do
    assigns =
      assigns
      |> assign(:sync_message, sync_status_message(assigns.provider.sync_status))
      |> assign(:sync_progress_label, sync_progress_label(assigns.sync_progress))

    ~H"""
    <div
      data-sync-status={@provider.sync_status}
      class="flex h-full min-w-0 flex-col rounded-xl border border-border bg-surface p-4 transition-colors hover:border-brand/30"
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <h3 class="font-semibold text-text-primary truncate">{@provider.name}</h3>
          <p class="text-sm text-text-secondary truncate">{@provider.url}</p>
        </div>
        <.sync_status_badge status={@provider.sync_status} />
      </div>

      <p
        :if={@sync_message}
        data-sync-state-message
        class={[
          "mt-2 text-xs",
          @provider.sync_status == "failed" && "text-error",
          @provider.sync_status != "failed" && "text-text-muted"
        ]}
      >
        {@sync_message}
      </p>

      <div
        :if={@sync_progress}
        data-sync-progress
        class="mt-3 rounded-lg border border-border bg-surface-hover/45 p-3"
      >
        <div class="mb-2 flex items-center justify-between gap-3 text-xs">
          <span class="truncate font-medium text-text-primary">{@sync_progress_label}</span>
          <span class="tabular-nums text-text-muted">{@sync_progress.percent}%</span>
        </div>
        <div
          class="h-1.5 overflow-hidden rounded-full bg-border"
          role="progressbar"
          aria-label={@sync_progress_label}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow={@sync_progress.percent}
        >
          <div
            class="h-full rounded-full bg-brand transition-[width] duration-300"
            style={"width: #{@sync_progress.percent}%"}
          />
        </div>
      </div>

      <div class="mt-4 min-h-12 text-sm text-text-secondary">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <div
            :if={@provider.live_channels_count && @provider.live_channels_count > 0}
            class="flex items-center gap-1.5"
          >
            <.icon name="hero-tv" class="size-4 shrink-0" />
            <span>{@provider.live_channels_count} ao vivo</span>
          </div>
          <div
            :if={@provider.movies_count && @provider.movies_count > 0}
            class="flex items-center gap-1.5"
          >
            <.icon name="hero-film" class="size-4 shrink-0" />
            <span>{@provider.movies_count} filmes</span>
          </div>
          <div
            :if={@provider.series_count && @provider.series_count > 0}
            class="flex items-center gap-1.5"
          >
            <.icon name="hero-video-camera" class="size-4 shrink-0" />
            <span>{@provider.series_count} séries</span>
          </div>
          <div :if={@provider.live_synced_at} class="flex items-center gap-1.5">
            <.icon name="hero-clock" class="size-4 shrink-0" />
            <span>{format_relative_time(@provider.live_synced_at)}</span>
          </div>
        </div>
      </div>

      <div class="mt-auto flex flex-wrap items-center justify-end gap-1 border-t border-border pt-3 sm:gap-2">
        <button
          type="button"
          phx-click={@on_sync}
          phx-value-id={@provider.id}
          disabled={
            @provider.sync_status in ["pending", "syncing", "paused_quota", "paused_upstream"]
          }
          class="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-3 py-2 text-sm text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary disabled:cursor-wait disabled:opacity-50"
        >
          <.icon
            name="hero-arrow-path"
            class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
          /> Sincronizar
        </button>
        <.link
          navigate={~p"/providers/#{@provider.id}"}
          aria-label="Ver provedor"
          class="inline-flex min-h-11 items-center gap-1.5 rounded-md px-3 py-2 text-sm text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
        >
          <.icon name="hero-eye" class="size-4" /> Ver
        </.link>
        <button
          type="button"
          phx-click={@on_edit}
          phx-value-id={@provider.id}
          aria-label="Editar provedor"
          class="flex size-11 items-center justify-center rounded-md text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
        >
          <.icon name="hero-pencil" class="size-4" />
        </button>
        <button
          type="button"
          phx-click={@on_delete}
          phx-value-id={@provider.id}
          data-confirm="Tem certeza que deseja excluir este provedor?"
          aria-label="Excluir provedor"
          class="flex size-11 items-center justify-center rounded-md text-text-secondary transition-colors hover:bg-error/10 hover:text-error"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp sync_status_message("pending"), do: "Sincronização aguardando processamento."
  defp sync_status_message("syncing"), do: "Sincronizando o catálogo deste provedor."

  defp sync_status_message("paused_quota"),
    do: "Sincronização pausada até a renovação da cota diária."

  defp sync_status_message("paused_upstream"),
    do: "Sincronização pausada enquanto a origem limita novas requisições."

  defp sync_status_message("partial"),
    do: "Sincronização concluída parcialmente; algumas origens serão tentadas novamente."

  defp sync_status_message("failed"), do: "A última sincronização falhou. Tente novamente."
  defp sync_status_message(_status), do: nil

  defp sync_progress_label(nil), do: nil

  defp sync_progress_label(%{phase: phase, type: type}) do
    base = sync_phase_label(phase)

    case type do
      value when value in [nil, "", :all] -> base
      value -> "#{base} · #{format_sync_type(value)}"
    end
  end

  defp sync_phase_label(:queued), do: "Na fila de sincronização"
  defp sync_phase_label(:categories), do: "Sincronizando categorias"
  defp sync_phase_label(:live), do: "Sincronizando canais"
  defp sync_phase_label(:movies), do: "Sincronizando filmes"
  defp sync_phase_label(:series), do: "Sincronizando séries"
  defp sync_phase_label(:series_details), do: "Atualizando episódios"
  defp sync_phase_label(:metadata), do: "Atualizando metadados"
  defp sync_phase_label(:cleanup), do: "Finalizando catálogo"
  defp sync_phase_label(_phase), do: "Sincronizando catálogo"

  defp format_sync_type(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp sync_status_badge(assigns) do
    {bg, text, label} = Map.get(@sync_status_badges, assigns.status, @unknown_sync_badge)

    assigns = assign(assigns, bg: bg, text: text, label: label)

    ~H"""
    <span class={["inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium", @bg, @text]}>
      {@label}
    </span>
    """
  end

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
    stream_url = Streamix.Playback.live_channel_stream_url(assigns.channel, assigns.provider)

    proxy_url =
      if assigns.use_proxy do
        proxy_base =
          Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.fun")

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
        ></video>
      </div>
    </div>
    """
  end
end
