defmodule StreamixWeb.AppComponents do
  @moduledoc """
  Application-specific UI components for Streamix.
  Uses pure Tailwind CSS v4 with custom theme variables.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  alias Streamix.Iptv.LiveChannel
  alias StreamixWeb.Helpers.ImageProxy

  @doc """
  Renders a theme toggle button.
  """
  attr :class, :string, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <button
      id={"theme-toggle-#{System.unique_integer()}"}
      type="button"
      phx-hook="ThemeToggle"
      class={[
        "flex items-center gap-2 p-2 rounded-lg text-text-secondary hover:text-text-primary hover:bg-surface-hover transition-colors",
        @class
      ]}
      title="Alternar tema"
    >
      <!-- Sun icon (for dark mode) -->
      <.icon name="hero-sun" class="hidden dark:block size-5" />
      <!-- Moon icon (for light mode) -->
      <.icon name="hero-moon" class="block dark:hidden size-5" />
      <span class="sr-only">Alternar tema</span>
    </button>
    """
  end

  @doc """
  Renders the sidebar navigation.
  """
  attr :current_scope, :any, default: nil
  attr :current_path, :string, default: "/"

  def sidebar(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-4 border-b border-border">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-xl font-bold text-brand">
          <.icon name="hero-play-circle-solid" class="size-8" />
          <span>Streamix</span>
        </.link>
      </div>

      <nav class="flex-1 p-4 space-y-6">
        <div :if={@current_scope} class="space-y-1">
          <p class="text-xs font-semibold text-text-muted uppercase tracking-wider px-3 mb-2">
            Menu
          </p>
          <.nav_item
            path={~p"/providers"}
            icon="hero-server-stack"
            label="Provedores"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/search"}
            icon="hero-magnifying-glass"
            label="Buscar"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/plans"}
            icon="hero-sparkles"
            label="Planos"
            current_path={@current_path}
          />
        </div>

        <div :if={@current_scope} class="space-y-1">
          <p class="text-xs font-semibold text-text-muted uppercase tracking-wider px-3 mb-2">
            Biblioteca
          </p>
          <.nav_item
            path={~p"/favorites"}
            icon="hero-heart"
            label="Favoritos"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/history"}
            icon="hero-clock"
            label="Histórico"
            current_path={@current_path}
          />
        </div>
      </nav>

      <div class="p-4 border-t border-border">
        <div :if={@current_scope} class="space-y-1">
          <.nav_item
            :if={Streamix.Accounts.admin?(@current_scope.user)}
            path={~p"/admin"}
            icon="hero-shield-check"
            label="Gerenciamento"
            current_path={@current_path}
          />
          <.nav_item
            path={~p"/settings"}
            icon="hero-cog-6-tooth"
            label="Configurações"
            current_path={@current_path}
          />
          <.link
            href={~p"/logout"}
            method="delete"
            class="flex items-center gap-3 px-3 py-2 rounded-lg text-text-secondary hover:bg-surface-hover hover:text-text-primary transition-colors w-full"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
            <span>Sair</span>
          </.link>
        </div>

        <div :if={!@current_scope} class="space-y-2">
          <.link
            navigate={~p"/plans"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg border border-brand/30 bg-brand/10 text-brand hover:bg-brand/20 transition-colors w-full"
          >
            <.icon name="hero-sparkles" class="size-5" />
            <span>Ver planos premium</span>
          </.link>
          <.link
            navigate={~p"/login"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg bg-brand text-white hover:bg-brand-hover transition-colors w-full"
          >
            <.icon name="hero-arrow-right-end-on-rectangle" class="size-5" />
            <span>Entrar</span>
          </.link>
          <.link
            navigate={~p"/register"}
            class="flex items-center justify-center gap-2 px-3 py-2 rounded-lg border border-border text-text-secondary hover:bg-surface-hover hover:text-text-primary transition-colors w-full"
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
        @active && "bg-brand/20 text-brand font-medium",
        !@active && "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Desktop top nav link with icon and active state.
  """
  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :active, :boolean, default: false
  attr :accent, :string, default: nil

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm font-medium transition-all",
        @active && !@accent && "text-text-primary bg-surface-hover/60",
        !@active && !@accent &&
          "text-text-secondary hover:text-text-primary hover:bg-surface-hover/40",
        @active && @accent == "purple" && "text-purple-300 bg-purple-500/10",
        !@active && @accent == "purple" &&
          "text-purple-400 hover:text-purple-300 hover:bg-purple-500/10"
      ]}
    >
      <.icon name={if @active, do: @icon_active, else: @icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Mobile bottom navigation tab.
  """
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :icon_active, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :center, :boolean, default: false

  def bottom_tab(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex flex-col items-center justify-center flex-1 h-full py-1.5 transition-all touch-manipulation",
        @active && "text-brand",
        !@active && "text-text-secondary active:text-text-primary"
      ]}
    >
      <span class={[
        "flex items-center justify-center rounded-2xl transition-all",
        @active && "bg-brand/15 px-4 py-1",
        !@active && "px-2 py-1"
      ]}>
        <.icon
          name={if @active, do: @icon_active, else: @icon}
          class={["transition-all", @center && "size-6", !@center && "size-5"]}
        />
      </span>
      <span class="text-[10px] mt-0.5 font-medium">{@label}</span>
    </.link>
    """
  end

  @doc """
  Dropdown menu item.
  """
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global

  def dropdown_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-2.5 px-4 py-2 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover/50 transition-colors"
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Renders a compact premium badge.
  """
  attr :class, :string, default: nil
  attr :label, :string, default: "Premium"

  def premium_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full border border-brand/30 bg-brand/10 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.18em] text-brand",
      @class
    ]}>
      <.icon name="hero-sparkles" class="size-3.5" />
      {@label}
    </span>
    """
  end

  @doc """
  Renders a plan entitlement badge.
  """
  attr :class, :string, default: nil
  attr :grants_global_access, :boolean, default: false
  attr :id, :string, default: nil

  def plan_access_badge(assigns) do
    assigns =
      assign(assigns,
        label: if(assigns.grants_global_access, do: "Premium", else: "Disponível sob ativação"),
        icon: if(assigns.grants_global_access, do: "hero-sparkles", else: "hero-clock"),
        variant: if(assigns.grants_global_access, do: "premium", else: "neutral")
      )

    ~H"""
    <span
      id={@id}
      data-variant={@variant}
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.18em]",
        @grants_global_access &&
          "border-brand/30 bg-brand/10 text-brand",
        !@grants_global_access &&
          "border-border bg-surface-hover text-text-secondary",
        @class
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </span>
    """
  end

  @doc """
  Renders a premium upsell banner with a CTA to the plans page.
  """
  attr :class, :string, default: nil
  attr :current_scope, :any, default: nil
  attr :description, :string, default: nil
  attr :id, :string, default: "premium-cta-banner"
  attr :navigate, :string, default: nil
  attr :title, :string, default: nil
  attr :cta_label, :string, default: nil

  def premium_cta_banner(assigns) do
    # Hide for admin users
    if assigns.current_scope && Streamix.Accounts.admin?(assigns.current_scope.user) do
      ~H""
    else
      render_premium_cta_banner(assigns)
    end
  end

  defp render_premium_cta_banner(assigns) do
    assigns = assign(assigns, :navigate, assigns.navigate || ~p"/plans")

    defaults =
      if assigns.current_scope do
        %{
          title: "Liberte o acesso global ao catálogo",
          description:
            "Ative um plano premium para acessar o catálogo global sem bloqueios e acompanhar sua assinatura em um só lugar.",
          cta_label: "Ver planos"
        }
      else
        %{
          title: "Conheça os planos premium",
          description:
            "Acesse o catálogo global e confira o que cada plano oferece antes de entrar ou criar sua conta.",
          cta_label: "Explorar planos"
        }
      end

    assigns =
      assigns
      |> assign_new(:title, fn -> defaults.title end)
      |> assign_new(:description, fn -> defaults.description end)
      |> assign_new(:cta_label, fn -> defaults.cta_label end)

    ~H"""
    <section
      id={@id}
      class={[
        "rounded-2xl border border-brand/20 bg-gradient-to-br from-brand/15 via-surface to-accent/10 p-5 sm:p-6 shadow-lg shadow-brand/10",
        @class
      ]}
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div class="space-y-2">
          <.premium_badge />
          <h2 class="text-xl sm:text-2xl font-semibold text-text-primary">{@title}</h2>
          <p class="text-sm sm:text-base text-text-secondary max-w-2xl">{@description}</p>
        </div>

        <.link
          navigate={@navigate}
          class="inline-flex items-center justify-center gap-2 rounded-xl bg-brand px-4 py-2.5 font-semibold text-white transition-all hover:-translate-y-0.5 hover:bg-brand-hover"
        >
          <.icon name="hero-sparkles" class="size-5" />
          {@cta_label}
        </.link>
      </div>
    </section>
    """
  end

  @doc """
  Renders a live channel card.
  Uses <.link> for reliable navigation instead of phx-click.
  """
  attr :channel, :map, required: true
  attr :current_program, :any, default: nil
  attr :is_favorite, :boolean, default: false
  attr :show_favorite, :boolean, default: true
  attr :show_epg, :boolean, default: true
  attr :on_favorite, :string, default: "toggle_favorite"

  def live_channel_card(assigns) do
    ~H"""
    <div class="group relative flex flex-col gap-1 sm:gap-2 transition-all duration-300">
      <.link
        navigate={~p"/watch/live_channel/#{@channel.id}"}
        class="block relative aspect-video bg-surface-hover cursor-pointer rounded-md sm:rounded-lg overflow-hidden shadow-md group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1"
      >
        <div
          id={"channel-img-#{@channel.id}"}
          phx-hook="ImageFallback"
          class="w-full h-full"
        >
          <img
            :if={@channel.stream_icon not in [nil, ""]}
            src={ImageProxy.proxy(@channel.stream_icon)}
            alt={@channel.name}
            class="w-full h-full object-contain p-1 sm:p-2"
            loading="lazy"
            data-fallback-target
          />
          <div
            data-fallback
            class={[
              "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
              @channel.stream_icon not in [nil, ""] && "hidden"
            ]}
          >
            <.icon name="hero-tv" class="size-5 sm:size-8 text-brand/60 mb-1" />
            <span class="text-[8px] sm:text-xs text-text-muted leading-tight line-clamp-2">
              {@channel.name}
            </span>
          </div>
        </div>
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-8 sm:size-16 text-brand" />
        </div>
      </.link>
      <div class="px-0.5 sm:px-1">
        <div class="flex items-start justify-between gap-1">
          <.link
            navigate={~p"/watch/live_channel/#{@channel.id}"}
            class="font-medium text-[11px] sm:text-sm text-text-primary truncate flex-1 group-hover:text-brand transition-colors leading-tight mt-0.5"
            title={@channel.name}
          >
            {@channel.name}
          </.link>
          <button
            :if={@show_favorite}
            type="button"
            phx-click={@on_favorite}
            phx-value-id={@channel.id}
            class={[
              "shrink-0 p-1 sm:p-1.5 rounded-full transition-all focus:opacity-100 mt-0.5",
              @is_favorite && "text-brand bg-brand/10 opacity-100",
              !@is_favorite &&
                "text-text-secondary hover:text-brand hover:bg-brand/10 opacity-0 group-hover:opacity-100"
            ]}
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-3.5 sm:size-5", @is_favorite && "text-brand"]}
            />
          </button>
        </div>

        <StreamixWeb.EpgComponents.epg_now
          :if={@show_epg}
          current_program={@current_program || Map.get(@channel, :current_program)}
          compact={true}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a provider card with sync status.
  """
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
          class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary hover:bg-surface-hover rounded-md transition-colors disabled:opacity-50"
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

  @doc """
  Renders the video player modal for live channels.
  """
  attr :channel, :map, required: true
  attr :provider, :map, required: true
  attr :on_close, :string, default: "close_player"
  attr :use_proxy, :boolean, default: true

  def video_player_v2(assigns) do
    stream_url = LiveChannel.stream_url(assigns.channel, assigns.provider)

    # Use external nginx proxy (source.mahina.cloud) instead of local Phoenix proxy
    # This avoids consuming Elixir VM resources for streaming
    proxy_url =
      if assigns.use_proxy do
        proxy_base =
          Application.get_env(:streamix, :stream_proxy_url, "https://source.mahina.cloud")

        "#{proxy_base}/proxy?url=#{stream_url}"
      else
        nil
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
          autoplay
          playsinline
        >
        </video>
      </div>
    </div>
    """
  end

  @doc """
  Renders a category filter dropdown.
  """
  attr :categories, :list, required: true
  attr :selected, :any, default: nil
  attr :on_change, :string, default: "filter_category"

  def category_filter_v2(assigns) do
    selected_name = find_category_name(assigns.categories, assigns.selected)
    assigns = assign(assigns, :selected_name, selected_name)

    ~H"""
    <div class="relative" x-data="{ open: false }" @click.outside="open = false">
      <button
        type="button"
        class="inline-flex items-center gap-2 px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary bg-surface border border-border rounded-lg hover:bg-surface-hover transition-colors"
        @click="open = !open"
      >
        <.icon name="hero-funnel" class="size-4" />
        <span>{@selected_name || "Todas as Categorias"}</span>
        <span class="transition-transform" x-bind:class="open && 'rotate-180'">
          <.icon name="hero-chevron-down" class="size-4" />
        </span>
      </button>
      <div
        x-show="open"
        x-transition:enter="transition ease-out duration-100"
        x-transition:enter-start="opacity-0 scale-95"
        x-transition:enter-end="opacity-100 scale-100"
        x-transition:leave="transition ease-in duration-75"
        x-transition:leave-start="opacity-100 scale-100"
        x-transition:leave-end="opacity-0 scale-95"
        style="display: none"
        class="absolute left-0 z-50 mt-2 w-56 max-h-96 overflow-y-auto bg-surface border border-border rounded-lg shadow-xl origin-top-left"
      >
        <div class="py-1">
          <button
            type="button"
            phx-click={@on_change}
            phx-value-category=""
            class={[
              "w-full px-4 py-2 text-left text-sm hover:bg-surface-hover transition-colors",
              !@selected && "text-brand font-medium bg-brand/5"
            ]}
            @click="open = false"
          >
            Todas as Categorias
          </button>
          <button
            :for={category <- @categories}
            type="button"
            phx-click={@on_change}
            phx-value-category={category.id}
            class={[
              "w-full px-4 py-2 text-left text-sm hover:bg-surface-hover transition-colors",
              to_string(@selected) == to_string(category.id) && "text-brand font-medium bg-brand/5"
            ]}
            @click="open = false"
          >
            {category.name}
          </button>
        </div>
      </div>
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
  """
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Buscar..."
  attr :on_change, :string, default: "search"

  def search_input(assigns) do
    ~H"""
    <form phx-change={@on_change} phx-submit={@on_change} class="flex-1 max-w-md">
      <div class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-text-muted"
        />
        <input
          type="search"
          name="search"
          value={@value}
          placeholder={@placeholder}
          phx-debounce="300"
          class="w-full pl-10 pr-4 py-2 text-sm bg-surface border border-border rounded-lg text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-brand focus:border-transparent"
        />
      </div>
    </form>
    """
  end

  @doc """
  Renders an empty state message.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16 text-center">
      <div class="rounded-full bg-surface-hover p-6 mb-4">
        <.icon name={@icon} class="size-12 text-text-muted" />
      </div>
      <h3 class="text-lg font-medium text-text-primary mb-1">{@title}</h3>
      <p :if={@message} class="text-text-secondary mb-6 max-w-md">{@message}</p>
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
        "sm" -> "size-4"
        "md" -> "size-6"
        "lg" -> "size-8"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <svg class={["animate-spin text-brand", @size_class]} fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  @doc """
  Renders a history item card.
  """
  attr :entry, :map, required: true

  def history_card_v2(assigns) do
    ~H"""
    <div class="group flex items-center gap-3 sm:gap-4 p-2 sm:p-3 rounded-xl cursor-pointer transition-all duration-300 hover:bg-surface-hover/50 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-brand/5 border border-transparent hover:border-border/40">
      <div class="w-16 h-12 sm:w-20 sm:h-14 rounded-lg bg-surface-hover flex items-center justify-center shrink-0 overflow-hidden shadow-sm group-hover:shadow-md transition-shadow">
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
          class="size-6 text-text-muted"
        />
      </div>
      <div class="flex-1 min-w-0">
        <h4 class="font-medium text-sm sm:text-base text-text-primary truncate group-hover:text-brand transition-colors">
          {@entry.content_name || "Desconhecido"}
        </h4>
        <p class="text-sm text-text-secondary flex items-center gap-2">
          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs bg-surface-hover text-text-muted">
            {format_content_type(@entry.content_type)}
          </span>
          <span>{format_relative_time(@entry.watched_at)}</span>
          <span :if={@entry.duration_seconds}>- {format_duration(@entry.duration_seconds)}</span>
        </p>
      </div>
      <.icon name="hero-play-circle" class="size-8 text-brand shrink-0" />
    </div>
    """
  end

  @doc """
  Renders a favorite card.
  """
  attr :favorite, :map, required: true

  def favorite_card(assigns) do
    ~H"""
    <div class="group cursor-pointer flex flex-col gap-1 sm:gap-2 transition-all duration-300">
      <div class="relative aspect-video bg-surface-hover flex items-center justify-center rounded-lg overflow-hidden shadow-md group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1">
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
          class="size-12 text-text-muted"
        />
        <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
          <.icon name="hero-play-circle-solid" class="size-12 text-brand" />
        </div>
      </div>
      <div class="px-0.5 sm:px-1">
        <h3
          class="font-medium text-sm text-text-primary truncate group-hover:text-brand transition-colors mt-0.5"
          title={@favorite.content_name}
        >
          {@favorite.content_name || "Desconhecido"}
        </h3>
        <span class="inline-flex items-center mt-1 px-1.5 py-0.5 rounded text-xs bg-surface-hover text-text-muted">
          {format_content_type(@favorite.content_type)}
        </span>
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
