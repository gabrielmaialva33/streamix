defmodule StreamixWeb.WatchPartyLive.Join do
  @moduledoc """
  Join page for Watch Party — shows content info and lets user join.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.WatchPartyComponents

  alias Streamix.WatchParty
  alias StreamixWeb.Helpers.ImageProxy

  def mount(%{"invite_code" => invite_code}, _session, socket) do
    case WatchParty.get_room_by_invite(invite_code) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Watch Party não encontrada ou já encerrou")
         |> push_navigate(to: ~p"/")}

      room ->
        socket =
          socket
          |> assign(page_title: "Watch Party — #{room.content_name}")
          |> assign(current_path: "/party")
          |> assign(room: room)

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
        <div class="bg-surface rounded-2xl border border-border p-6 text-center space-y-6">
          <%!-- Content thumbnail --%>
          <div :if={@room.content_icon} class="relative mx-auto w-32 h-48 rounded-lg overflow-hidden">
            <img
              src={ImageProxy.proxy(@room.content_icon)}
              alt={@room.content_name}
              class="w-full h-full object-cover"
              crossorigin="anonymous"
            />
          </div>

          <div class="space-y-2">
            <h1 class="text-xl font-bold text-text-primary">Watch Party</h1>
            <p class="text-text-secondary">{@room.content_name || "Conteúdo"}</p>
            <.invite_badge invite_code={@room.invite_code} />
          </div>

          <button
            type="button"
            phx-click="join"
            class="w-full px-6 py-3 bg-purple-600 text-white font-bold rounded-lg hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/30 text-base"
          >
            <.icon name="hero-users" class="size-5 inline mr-2" /> Entrar na Sala
          </button>

          <.link navigate={~p"/"} class="block text-sm text-text-muted hover:text-text-secondary transition-colors">
            Voltar
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
