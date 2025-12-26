defmodule StreamixWeb.AppComponents do
  @moduledoc """
  Application-specific UI components for Streamix.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias Streamix.Iptv.LiveChannel

  @doc """
  Renders the sidebar navigation.

  ## Examples

      <.sidebar current_scope={@current_scope} current_path={@current_path} />
  """
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: "/"

  def sidebar(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-4 border-b border-base-300">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-xl font-bold text-primary">
          <.icon name="hero-play-circle-solid" class="size-8" />
          <span>Streamix</span>
        </.link>
      </div>

      <nav class="flex-1 p-4 space-y-2">
        <div :if={@current_scope} class="space-y-2">
          <.nav_item
            path={~p"/providers"}
            icon="hero-server-stack"
            label="Provedores"
            current_path={@current_path}
          />
        </div>
      </nav>

      <div class="p-4 border-t border-base-300">
        <div :if={@current_scope} class="space-y-2">
          <.nav_item
            path={~p"/settings"}
            icon="hero-cog-6-tooth"
            label="Configurações"
            current_path={@current_path}
          />
          <.link
            href={~p"/logout"}
            method="delete"
            class="flex items-center gap-3 px-3 py-2 rounded-lg text-base-content/70 hover:bg-base-300 hover:text-base-content transition-colors w-full"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
            <span>Sair</span>
          </.link>
        </div>

        <div :if={!@current_scope} class="space-y-2">
          <.link
            navigate={~p"/login"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg bg-primary text-primary-content hover:bg-primary/80 transition-colors w-full"
          >
            <.icon name="hero-arrow-right-end-on-rectangle" class="size-5" />
            <span>Entrar</span>
          </.link>
          <.link
            navigate={~p"/register"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg border border-base-300 hover:bg-base-300 transition-colors w-full"
          >
            <.icon name="hero-user-plus" class="size-5" />
            <span>Cadastrar</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp nav_item(assigns) do
    active = assigns.current_path == assigns.path

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg transition-colors",
        @active && "bg-primary/20 text-primary font-medium",
        !@active && "text-base-content/70 hover:bg-base-300 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Renders a live channel card (new structure).

  ## Examples

      <.live_channel_card channel={@channel} is_favorite={false} />
  """
  attr :channel, :map, required: true
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :on_play, :string, default: "play_channel"
  attr :on_favorite, :string, default: "toggle_favorite"

  def live_channel_card(assigns) do
    ~H"""
    <div class="card bg-base-200 hover:bg-base-300 transition-colors group cursor-pointer">
      <figure
        class="relative aspect-video bg-base-300"
        phx-click={@on_play}
        phx-value-id={@channel.id}
      >
        <img
          :if={@channel.stream_icon}
          src={@channel.stream_icon}
          alt={@channel.name}
          class="w-full h-full object-contain p-2"
          loading="lazy"
          onerror="this.style.display='none'"
        />
        <div
          :if={!@channel.stream_icon}
          class="w-full h-full flex items-center justify-center text-base-content/30"
        >
          <.icon name="hero-tv" class="size-12" />
        </div>
        <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-16 text-primary" />
        </div>
      </figure>
      <div class="card-body p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="font-medium text-sm truncate" title={@channel.name}>
              {@channel.name}
            </h3>
          </div>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@channel.id}
            class="flex-shrink-0 p-1 hover:scale-110 transition-transform"
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-5", @is_favorite && "text-error"]}
            />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a provider card with sync status.

  ## Examples

      <.provider_card provider={@provider} />
  """
  attr :provider, :map, required: true
  attr :on_sync, :string, default: "sync_provider"
  attr :on_edit, :string, default: "edit_provider"
  attr :on_delete, :string, default: "delete_provider"

  def provider_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="min-w-0 flex-1">
            <h3 class="font-semibold truncate">{@provider.name}</h3>
            <p class="text-sm text-base-content/60 truncate">{@provider.url}</p>
          </div>
          <.sync_status_badge status={@provider.sync_status} />
        </div>

        <div class="flex flex-wrap items-center gap-4 text-sm text-base-content/70 mt-2">
          <div :if={@provider.live_count && @provider.live_count > 0} class="flex items-center gap-1">
            <.icon name="hero-tv" class="size-4" />
            <span>{@provider.live_count} ao vivo</span>
          </div>
          <div
            :if={@provider.movies_count && @provider.movies_count > 0}
            class="flex items-center gap-1"
          >
            <.icon name="hero-film" class="size-4" />
            <span>{@provider.movies_count} filmes</span>
          </div>
          <div
            :if={@provider.series_count && @provider.series_count > 0}
            class="flex items-center gap-1"
          >
            <.icon name="hero-video-camera" class="size-4" />
            <span>{@provider.series_count} séries</span>
          </div>
          <div :if={@provider.last_synced_at} class="flex items-center gap-1">
            <.icon name="hero-clock" class="size-4" />
            <span>{format_relative_time(@provider.last_synced_at)}</span>
          </div>
        </div>

        <div class="card-actions justify-end mt-3">
          <button
            type="button"
            phx-click={@on_sync}
            phx-value-id={@provider.id}
            disabled={@provider.sync_status in ["pending", "syncing"]}
            class="btn btn-sm btn-ghost"
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
            /> Sincronizar
          </button>
          <.link navigate={~p"/providers/#{@provider.id}"} class="btn btn-sm btn-ghost">
            <.icon name="hero-eye" class="size-4" /> Ver
          </.link>
          <button
            type="button"
            phx-click={@on_edit}
            phx-value-id={@provider.id}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-pencil" class="size-4" />
          </button>
          <button
            type="button"
            phx-click={@on_delete}
            phx-value-id={@provider.id}
            data-confirm="Tem certeza que deseja excluir este provedor?"
            class="btn btn-sm btn-ghost text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp sync_status_badge(assigns) do
    {color, label} =
      case assigns.status do
        "idle" -> {"badge-ghost", "Inativo"}
        "pending" -> {"badge-warning", "Pendente"}
        "syncing" -> {"badge-info", "Sincronizando"}
        "completed" -> {"badge-success", "Sincronizado"}
        "failed" -> {"badge-error", "Falhou"}
        _ -> {"badge-ghost", "Desconhecido"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class={["badge badge-sm", @color]}>{@label}</span>
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

  @doc """
  Renders the video player modal for live channels (v2).

  ## Examples

      <.video_player_v2 channel={@playing_channel} provider={@provider} />
  """
  attr :channel, :map, required: true
  attr :provider, :map, required: true
  attr :on_close, :string, default: "close_player"
  attr :use_proxy, :boolean, default: true

  def video_player_v2(assigns) do
    stream_url = LiveChannel.stream_url(assigns.channel, assigns.provider)
    proxy_url = if assigns.use_proxy, do: proxy_stream_url(stream_url), else: nil
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
        class="absolute top-4 right-4 z-10 btn btn-circle btn-ghost text-white"
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
          class="w-full h-full bg-black"
          controls
          autoplay
          playsinline
        >
        </video>
      </div>
    </div>
    """
  end

  defp proxy_stream_url(stream_url) when is_binary(stream_url) do
    encoded = Base.url_encode64(stream_url, padding: false)
    "/api/stream/proxy?url=#{encoded}"
  end

  defp proxy_stream_url(_), do: nil

  @doc """
  Renders a category filter dropdown (v2 - with id/name structure).

  ## Examples

      <.category_filter_v2 categories={@categories} selected={@selected_category} />
  """
  attr :categories, :list, required: true
  attr :selected, :any, default: nil
  attr :on_change, :string, default: "filter_category"

  def category_filter_v2(assigns) do
    selected_name = find_category_name(assigns.categories, assigns.selected)
    assigns = assign(assigns, :selected_name, selected_name)

    ~H"""
    <div class="dropdown">
      <div tabindex="0" role="button" class="btn btn-sm btn-ghost gap-2">
        <.icon name="hero-funnel" class="size-4" />
        <span>{@selected_name || "Todas as Categorias"}</span>
        <.icon name="hero-chevron-down" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content z-10 menu p-2 shadow bg-base-200 rounded-box w-52 max-h-96 overflow-y-auto"
      >
        <li>
          <button
            type="button"
            phx-click={@on_change}
            phx-value-category=""
            class={[!@selected && "active"]}
          >
            Todas as Categorias
          </button>
        </li>
        <li :for={category <- @categories}>
          <button
            type="button"
            phx-click={@on_change}
            phx-value-category={category.id}
            class={[to_string(@selected) == to_string(category.id) && "active"]}
          >
            {category.name}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp find_category_name(_categories, nil), do: nil

  defp find_category_name(categories, selected) do
    selected_str = to_string(selected)

    Enum.find_value(categories, fn cat ->
      if to_string(cat.id) == selected_str, do: cat.name
    end)
  end

  @doc """
  Renders a search input.

  ## Examples

      <.search_input value={@search} />
  """
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Buscar..."
  attr :on_change, :string, default: "search"

  def search_input(assigns) do
    ~H"""
    <form phx-change={@on_change} phx-submit={@on_change} class="flex-1 max-w-md">
      <label class="input input-sm input-bordered flex items-center gap-2">
        <.icon name="hero-magnifying-glass" class="size-4 text-base-content/50" />
        <input
          type="search"
          name="search"
          value={@value}
          placeholder={@placeholder}
          phx-debounce="300"
          class="grow bg-transparent border-none focus:outline-none"
        />
      </label>
    </form>
    """
  end

  @doc """
  Renders an empty state message.

  ## Examples

      <.empty_state icon="hero-tv" title="No channels" message="Add a provider to see channels" />
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-center">
      <div class="rounded-full bg-base-200 p-4 mb-4">
        <.icon name={@icon} class="size-12 text-base-content/30" />
      </div>
      <h3 class="text-lg font-medium mb-1">{@title}</h3>
      <p :if={@message} class="text-base-content/60 mb-4">{@message}</p>
      {render_slot(@action)}
    </div>
    """
  end

  @doc """
  Renders a loading spinner.
  """
  attr :size, :string, default: "md", values: ~w(sm md lg)

  def loading_spinner(assigns) do
    size_class =
      case assigns.size do
        "sm" -> "loading-sm"
        "md" -> "loading-md"
        "lg" -> "loading-lg"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <span class={["loading loading-spinner", @size_class]}></span>
    """
  end

  @doc """
  Renders infinite scroll trigger.
  """
  attr :has_more, :boolean, required: true
  attr :loading, :boolean, default: false

  def infinite_scroll(assigns) do
    ~H"""
    <div
      :if={@has_more}
      id="infinite-scroll-trigger"
      phx-hook="InfiniteScroll"
      class="flex justify-center py-8"
    >
      <.loading_spinner :if={@loading} />
    </div>
    """
  end

  @doc """
  Renders a history item card (v2 - with denormalized data).

  ## Examples

      <.history_card_v2 entry={@entry} />
  """
  attr :entry, :map, required: true

  def history_card_v2(assigns) do
    ~H"""
    <div class="flex items-center gap-4 p-3 rounded-lg bg-base-200 hover:bg-base-300 transition-colors">
      <div class="w-16 h-12 rounded bg-base-300 flex items-center justify-center flex-shrink-0 overflow-hidden">
        <img
          :if={@entry.content_icon}
          src={@entry.content_icon}
          alt={@entry.content_name}
          class="w-full h-full object-contain"
          loading="lazy"
        />
        <.icon
          :if={!@entry.content_icon}
          name={content_type_icon(@entry.content_type)}
          class="size-6 text-base-content/30"
        />
      </div>
      <div class="flex-1 min-w-0">
        <h4 class="font-medium truncate">{@entry.content_name || "Desconhecido"}</h4>
        <p class="text-sm text-base-content/60">
          <span class="badge badge-xs badge-ghost mr-1">
            {format_content_type(@entry.content_type)}
          </span>
          {format_relative_time(@entry.watched_at)}
          <span :if={@entry.duration_seconds}>
            - {format_duration(@entry.duration_seconds)}
          </span>
        </p>
      </div>
      <.icon name="hero-play-circle" class="size-8 text-primary flex-shrink-0" />
    </div>
    """
  end

  @doc """
  Renders a favorite card (with denormalized data).

  ## Examples

      <.favorite_card favorite={@favorite} />
  """
  attr :favorite, :map, required: true

  def favorite_card(assigns) do
    ~H"""
    <div class="card bg-base-200 hover:bg-base-300 transition-colors">
      <figure class="aspect-video bg-base-300 flex items-center justify-center">
        <img
          :if={@favorite.content_icon}
          src={@favorite.content_icon}
          alt={@favorite.content_name}
          class="w-full h-full object-contain p-2"
          loading="lazy"
        />
        <.icon
          :if={!@favorite.content_icon}
          name={content_type_icon(@favorite.content_type)}
          class="size-12 text-base-content/30"
        />
      </figure>
      <div class="card-body p-3">
        <h3 class="font-medium text-sm truncate" title={@favorite.content_name}>
          {@favorite.content_name || "Desconhecido"}
        </h3>
        <span class="badge badge-xs badge-ghost">{format_content_type(@favorite.content_type)}</span>
      </div>
    </div>
    """
  end

  defp content_type_icon("live_channel"), do: "hero-tv"
  defp content_type_icon("movie"), do: "hero-film"
  defp content_type_icon("series"), do: "hero-video-camera"
  defp content_type_icon("episode"), do: "hero-play"
  defp content_type_icon(_), do: "hero-play-circle"

  defp format_content_type("live_channel"), do: "Ao Vivo"
  defp format_content_type("movie"), do: "Filme"
  defp format_content_type("series"), do: "Série"
  defp format_content_type("episode"), do: "Episódio"
  defp format_content_type(type), do: type || "Desconhecido"

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "< 1m"
    end
  end

  defp format_duration(_), do: ""
end
