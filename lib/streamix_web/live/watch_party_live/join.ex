defmodule StreamixWeb.WatchPartyLive.Join do
  @moduledoc """
  Join page for Watch Party — shows content info and lets user join.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.WatchPartyComponents

  alias Streamix.Iptv.CatalogItem
  alias Streamix.WatchParty
  alias StreamixWeb.Helpers.ImageProxy

  def mount(%{"invite_code" => invite_code}, _session, socket) do
    case WatchParty.get_room_by_invite_with_content(invite_code) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Watch Party não encontrada ou já encerrou")
         |> push_navigate(to: ~p"/")}

      room ->
        content_name = CatalogItem.content_name(room.catalog_item)
        content_icon = CatalogItem.content_icon(room.catalog_item)

        socket =
          socket
          |> assign(page_title: "Watch Party — #{content_name || "Conteúdo"}")
          |> assign(current_path: "/party")
          |> assign(room: room)
          |> assign(room_content_name: content_name)
          |> assign(room_content_icon: content_icon)

        {:ok, socket}
    end
  end

  def handle_event("join", _, socket) do
    user_id = socket.assigns.current_scope.user.id
    room = socket.assigns.room

    case WatchParty.join_room(room.id, user_id) do
      {:ok, _participant} ->
        {:noreply, push_navigate(socket, to: ~p"/party/#{room.invite_code}/watch")}

      {:error, :room_full} ->
        {:noreply, put_flash(socket, :error, "A sala está cheia")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Erro ao entrar na sala")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-[80vh]">
      <div class="max-w-md w-full mx-4">
        <div class="bg-surface rounded-lg border border-border p-6 text-center space-y-6 shadow-card">
          <%!-- Content thumbnail --%>
          <div :if={@room_content_icon} class="relative mx-auto w-32 h-48 rounded-lg overflow-hidden">
            <img
              src={ImageProxy.proxy(@room_content_icon)}
              alt={@room_content_name}
              class="w-full h-full object-cover"
              crossorigin="anonymous"
              loading="lazy"
              decoding="async"
            />
          </div>

          <div class="space-y-2">
            <h1 class="text-xl font-bold text-text-primary">Watch Party</h1>
            <p class="text-text-secondary">{@room_content_name || "Conteúdo"}</p>
            <.invite_badge invite_code={@room.invite_code} />
          </div>

          <button
            type="button"
            phx-click="join"
            class="w-full px-6 py-3 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
          >
            <.icon name="hero-users" class="size-5 inline mr-2" /> Entrar na Sala
          </button>

          <.link
            navigate={~p"/"}
            class="block text-sm text-text-muted hover:text-text-secondary transition-colors focus:outline-none focus:ring-2 focus:ring-brand rounded"
          >
            Voltar
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
