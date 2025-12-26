defmodule StreamixWeb.HomeLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Início")
      |> assign(current_path: "/")
      |> load_dashboard_data()

    {:ok, socket}
  end

  defp load_dashboard_data(socket) do
    case socket.assigns.current_scope do
      nil ->
        socket
        |> assign(providers_count: 0)
        |> assign(favorites_count: 0)
        |> assign(history_count: 0)

      scope ->
        user_id = scope.user.id
        providers = Iptv.list_providers(user_id)
        favorites = Iptv.list_favorites(user_id, limit: 6)
        history = Iptv.list_watch_history(user_id, limit: 6)

        socket
        |> assign(providers: providers)
        |> assign(providers_count: length(providers))
        |> assign(favorites: favorites)
        |> assign(favorites_count: Iptv.count_favorites(user_id))
        |> assign(history: history)
        |> assign(history_count: length(history))
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="text-center py-8">
        <h1 class="text-4xl font-bold text-primary mb-2">Bem-vindo ao Streamix</h1>
        <p class="text-base-content/70">Sua plataforma pessoal de streaming IPTV</p>
      </div>

      <%= if @current_scope do %>
        <.authenticated_dashboard {assigns} />
      <% else %>
        <.guest_dashboard {assigns} />
      <% end %>
    </div>
    """
  end

  defp authenticated_dashboard(assigns) do
    ~H"""
    <div class="grid gap-6 md:grid-cols-3">
      <.stat_card
        title="Provedores"
        value={@providers_count}
        icon="hero-server-stack"
        href={~p"/providers"}
      />
      <.stat_card
        title="Favoritos"
        value={@favorites_count}
        icon="hero-heart"
        href={nil}
      />
      <.stat_card
        title="Recentes"
        value={@history_count}
        icon="hero-clock"
        href={nil}
      />
    </div>

    <div :if={@history != []} class="space-y-4">
      <h2 class="text-xl font-semibold">Continue Assistindo</h2>
      <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <.history_card_v2 :for={entry <- @history} entry={entry} />
      </div>
    </div>

    <div :if={@favorites != []} class="space-y-4">
      <h2 class="text-xl font-semibold">Favoritos</h2>
      <div class="grid gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-6">
        <.favorite_card :for={fav <- @favorites} favorite={fav} />
      </div>
    </div>

    <div :if={@providers_count == 0} class="text-center py-12">
      <.empty_state
        icon="hero-server-stack"
        title="Nenhum provedor ainda"
        message="Adicione seu primeiro provedor IPTV para começar a assistir"
      >
        <:action>
          <.button navigate={~p"/providers"} variant="primary">
            <.icon name="hero-plus" class="size-5" /> Adicionar Provedor
          </.button>
        </:action>
      </.empty_state>
    </div>
    """
  end

  defp guest_dashboard(assigns) do
    ~H"""
    <div class="text-center space-y-6">
      <p class="text-lg text-base-content/70">
        Entre para gerenciar seus provedores IPTV, salvar favoritos e acompanhar seu histórico.
      </p>
      <div class="flex justify-center gap-4">
        <.button navigate={~p"/login"} variant="primary">
          Entrar
        </.button>
        <.button navigate={~p"/register"}>
          Criar conta
        </.button>
      </div>
    </div>

    <div class="grid gap-6 md:grid-cols-3 mt-12">
      <div class="card bg-base-200 p-6 text-center">
        <.icon name="hero-server-stack" class="size-12 mx-auto text-primary mb-4" />
        <h3 class="font-semibold mb-2">Múltiplos Provedores</h3>
        <p class="text-sm text-base-content/70">Conecte vários serviços IPTV</p>
      </div>
      <div class="card bg-base-200 p-6 text-center">
        <.icon name="hero-film" class="size-12 mx-auto text-primary mb-4" />
        <h3 class="font-semibold mb-2">Filmes e Séries</h3>
        <p class="text-sm text-base-content/70">Navegue pelo catálogo VOD com metadados</p>
      </div>
      <div class="card bg-base-200 p-6 text-center">
        <.icon name="hero-tv" class="size-12 mx-auto text-primary mb-4" />
        <h3 class="font-semibold mb-2">TV ao Vivo</h3>
        <p class="text-sm text-base-content/70">Assista canais ao vivo com EPG</p>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <%= if @href do %>
      <.link
        navigate={@href}
        class="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer"
      >
        <div class="card-body flex-row items-center gap-4">
          <div class="rounded-full bg-primary/20 p-3">
            <.icon name={@icon} class="size-6 text-primary" />
          </div>
          <div>
            <p class="text-2xl font-bold">{@value}</p>
            <p class="text-sm text-base-content/60">{@title}</p>
          </div>
        </div>
      </.link>
    <% else %>
      <div class="card bg-base-200">
        <div class="card-body flex-row items-center gap-4">
          <div class="rounded-full bg-primary/20 p-3">
            <.icon name={@icon} class="size-6 text-primary" />
          </div>
          <div>
            <p class="text-2xl font-bold">{@value}</p>
            <p class="text-sm text-base-content/60">{@title}</p>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
