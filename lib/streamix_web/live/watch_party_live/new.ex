defmodule StreamixWeb.WatchPartyLive.New do
  @moduledoc """
  Explicit confirmation page for creating an idempotent Watch Party room.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.PlayerHelpers

  alias Streamix.{Access, WatchParty}
  alias StreamixWeb.Helpers.ImageProxy

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, content, provider} <- load_content_preflight(type, id, user.id),
         true <- Access.plays_global_content?(user, provider),
         {:ok, catalog_item_id} <- resolve_catalog_item_id(type, content) do
      title = content_title(content, type)
      icon = content_icon(content, type)

      {:ok,
       assign(socket,
         page_title: "Criar Watch Party — #{title}",
         current_path: "/party",
         content: content,
         content_type: type,
         content_title: title,
         content_icon: icon,
         catalog_item_id: catalog_item_id,
         creating: false,
         error: nil
       )}
    else
      false ->
        {:ok,
         socket
         |> put_flash(:error, "Seu plano não permite reproduzir esse conteúdo.")
         |> redirect(to: ~p"/plans?upgrade=global_catalog")}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Conteúdo indisponível para Watch Party")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Streamix.RateLimit.hit("party_create:#{user_id}", 60_000, 5) do
      {:allow, _remaining} ->
        create_room(socket, user_id)

      {:deny, retry_after} ->
        {:noreply,
         assign(socket,
           error: "Muitas salas criadas. Aguarde #{max(1, div(retry_after, 1_000))}s."
         )}
    end
  end

  defp create_room(socket, user_id) do
    socket = assign(socket, creating: true, error: nil)

    case WatchParty.create_room(user_id, %{
           catalog_item_id: socket.assigns.catalog_item_id,
           source_type: socket.assigns.content_type,
           source_id: socket.assigns.content.id
         }) do
      {:ok, room} ->
        {:noreply, push_navigate(socket, to: ~p"/party/#{room.invite_code}/watch")}

      {:error, :watch_party_not_allowed} ->
        {:noreply,
         socket
         |> put_flash(:error, "Watch Party exige um plano com esse recurso.")
         |> push_navigate(to: ~p"/plans?upgrade=watch_party")}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           creating: false,
           error: "Não foi possível criar a sala agora. Tente novamente."
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex min-h-[80vh] max-w-xl items-center px-4 py-10">
      <section class="surface-card w-full overflow-hidden" aria-labelledby="party-create-title">
        <div class="relative aspect-video bg-black/30">
          <img
            :if={@content_icon}
            src={ImageProxy.proxy(@content_icon)}
            alt=""
            class="h-full w-full object-cover opacity-70"
            crossorigin="anonymous"
            decoding="async"
          />
          <div class="absolute inset-0 bg-gradient-to-t from-surface via-surface/30 to-transparent" />
          <div class="absolute inset-x-0 bottom-0 px-6 pb-5">
            <div class="mb-2 inline-flex items-center gap-2 rounded-full bg-brand/90 px-3 py-1 text-xs font-semibold text-white">
              <.icon name="hero-users" class="size-4" /> Assistir junto
            </div>
            <h1 id="party-create-title" class="text-2xl font-bold text-white">
              {@content_title}
            </h1>
          </div>
        </div>

        <div class="space-y-5 p-6">
          <div>
            <h2 class="text-lg font-semibold text-text-primary">Criar uma Watch Party?</h2>
            <p class="mt-1 text-sm text-text-secondary">
              A sala começa pausada. Depois de entrar, compartilhe o código e controle a reprodução para todos.
            </p>
          </div>

          <p :if={@error} role="alert" class="rounded-lg bg-error/10 px-4 py-3 text-sm text-error">
            {@error}
          </p>

          <div class="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
            <.link
              navigate={~p"/party"}
              class="inline-flex min-h-11 items-center justify-center rounded-lg border border-border px-5 py-2.5 text-sm font-semibold text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"
            >
              Cancelar
            </.link>
            <button
              type="button"
              phx-click="create"
              phx-disable-with="Criando sala..."
              disabled={@creating}
              class="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-brand px-6 py-2.5 text-sm font-bold text-white transition-colors hover:bg-brand-hover focus:outline-none focus:ring-2 focus:ring-brand disabled:cursor-wait disabled:opacity-70"
            >
              <.icon name="hero-play-solid" class="size-5" /> Criar sala
            </button>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
