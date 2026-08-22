defmodule StreamixWeb.WatchPartyLive.Join do
  @moduledoc """
  Invite preflight for Watch Party.

  This page never persists membership. The authenticated player LiveView joins
  only after the content and playback-slot checks succeed on a connected socket.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.WatchPartyComponents

  alias Streamix.{Iptv, WatchParty}
  alias StreamixWeb.Helpers.ImageProxy

  @impl true
  def mount(%{"invite_code" => invite_code}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Streamix.RateLimit.hit("party_resolve:#{user_id}", 60_000, 30) do
      {:deny, retry_after} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "Muitas tentativas. Aguarde #{max(1, div(retry_after, 1_000))}s e tente novamente."
         )
         |> push_navigate(to: ~p"/party")}

      {:allow, _remaining} ->
        resolve_invite(socket, invite_code, user_id)
    end
  end

  defp resolve_invite(socket, invite_code, user_id) do
    with %{} = room <- WatchParty.get_room_by_invite_with_content(invite_code),
         :ok <- WatchParty.authorize_room_user(room, user_id) do
      content_name = Iptv.catalog_item_content_name(room.catalog_item)
      content_icon = Iptv.catalog_item_content_icon(room.catalog_item)
      capacity = WatchParty.room_capacity(room.id)

      {:ok,
       assign(socket,
         page_title: "Watch Party — #{content_name || "Conteúdo"}",
         current_path: "/party",
         room: room,
         room_content_name: content_name,
         room_content_icon: content_icon,
         capacity: capacity
       )}
    else
      nil ->
        unavailable_room(socket)

      {:error, :content_not_entitled} ->
        {:ok,
         socket
         |> put_flash(:error, "Seu plano não permite reproduzir o conteúdo desta sala.")
         |> redirect(to: ~p"/plans?upgrade=global_catalog")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Este conteúdo não está disponível para a sua conta.")
         |> redirect(to: ~p"/party")}
    end
  end

  defp unavailable_room(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Watch Party não encontrada ou já encerrada")
     |> redirect(to: ~p"/party")}
  end

  @impl true
  def handle_event("join", _params, socket) do
    room = socket.assigns.room
    {:noreply, push_navigate(socket, to: ~p"/party/#{room.invite_code}/watch")}
  end

  @impl true
  def render(assigns) do
    capacity = assigns.capacity
    room_full? = capacity.maximum > 0 and capacity.current >= capacity.maximum
    assigns = assign(assigns, :room_full?, room_full?)

    ~H"""
    <div class="flex min-h-[80vh] items-center justify-center px-4 py-10">
      <section
        class="surface-card w-full max-w-md space-y-6 p-6 text-center"
        aria-labelledby="party-join-title"
      >
        <div
          :if={@room_content_icon}
          class="relative mx-auto h-48 w-32 overflow-hidden rounded-lg bg-surface-hover"
        >
          <img
            src={ImageProxy.proxy(@room_content_icon)}
            alt=""
            class="h-full w-full object-cover"
            crossorigin="anonymous"
            loading="lazy"
            decoding="async"
          />
        </div>

        <div class="space-y-2">
          <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-brand/15 text-brand">
            <.icon name="hero-users" class="size-6" />
          </div>
          <h1 id="party-join-title" class="text-xl font-bold text-text-primary">
            Entrar na Watch Party
          </h1>
          <p class="text-text-secondary">{@room_content_name || "Conteúdo"}</p>
          <p class="text-xs text-text-muted">
            {@capacity.current}/{@capacity.maximum} participantes
          </p>
          <.invite_badge invite_code={@room.invite_code} />
        </div>

        <p
          :if={@room_full?}
          role="status"
          class="rounded-lg bg-warning/10 px-4 py-3 text-sm text-warning"
        >
          A sala está cheia agora. Uma vaga pode aparecer quando alguém sair.
        </p>

        <button
          type="button"
          phx-click="join"
          phx-disable-with="Abrindo sala..."
          class="inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand px-6 py-3 text-base font-bold text-white shadow-card transition-colors hover:bg-brand-hover focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
        >
          <.icon name="hero-play-solid" class="size-5" /> Entrar na sala
        </button>

        <.link
          navigate={~p"/party"}
          class="inline-flex min-h-11 items-center justify-center rounded-lg px-4 text-sm text-text-muted transition-colors hover:text-text-secondary focus:outline-none focus:ring-2 focus:ring-brand"
        >
          Voltar
        </.link>
      </section>
    </div>
    """
  end
end
