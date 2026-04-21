defmodule StreamixWeb.WatchPartyLive.Index do
  @moduledoc """
  Watch Party hub — enter a party via invite code or link.
  """
  use StreamixWeb, :live_view

  alias Streamix.WatchParty

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Watch Party")
      |> assign(current_path: "/party")
      |> assign(invite_input: "")
      |> assign(error: nil)

    {:ok, socket}
  end

  def handle_event("join", %{"invite" => invite}, socket) when byte_size(invite) > 0 do
    code = extract_code(String.trim(invite))

    if code do
      case WatchParty.get_room_by_invite(code) do
        nil ->
          {:noreply, assign(socket, error: "Sala não encontrada ou já encerrou")}

        room ->
          {:noreply, push_navigate(socket, to: ~p"/party/#{room.invite_code}")}
      end
    else
      {:noreply, assign(socket, error: "Código inválido")}
    end
  end

  def handle_event("join", _, socket) do
    {:noreply, assign(socket, error: "Digite um código ou cole um link")}
  end

  def handle_event("validate", %{"invite" => _invite}, socket) do
    {:noreply, assign(socket, error: nil)}
  end

  defp extract_code(value) do
    cond do
      # Full URL: /party/abc123 or /party/abc123/watch
      String.contains?(value, "/party/") ->
        case Regex.run(~r/\/party\/([a-z0-9]+)/i, value) do
          [_, code] -> String.downcase(code)
          _ -> nil
        end

      # Raw code (4-8 alphanumeric chars)
      Regex.match?(~r/^[a-z0-9]{4,8}$/i, value) ->
        String.downcase(value)

      true ->
        nil
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto px-4 sm:px-6 py-8 sm:py-12">
      <%!-- Hero --%>
      <div class="text-center mb-10 sm:mb-14">
        <div class="relative inline-flex items-center justify-center mb-5">
          <div class="absolute inset-0 bg-purple-600/30 blur-2xl rounded-full" aria-hidden="true" />
          <div class="relative w-20 h-20 rounded-2xl bg-gradient-to-br from-purple-500 to-purple-700 flex items-center justify-center shadow-xl shadow-purple-600/40">
            <.icon name="hero-users" class="size-10 text-white" />
          </div>
        </div>
        <h1 class="text-3xl sm:text-4xl font-bold text-text-primary tracking-tight">
          Watch Party
        </h1>
        <p class="text-text-secondary mt-3 text-base sm:text-lg max-w-xl mx-auto">
          Assista filmes, séries e TV ao vivo com seus amigos — tudo sincronizado e com chat em tempo real.
        </p>
      </div>

      <%!-- Two-column layout --%>
      <div class="grid lg:grid-cols-2 gap-4 sm:gap-6">
        <%!-- Card 1: Join --%>
        <div class="bg-surface rounded-2xl border border-border p-6 sm:p-8 flex flex-col">
          <div class="flex items-center gap-3 mb-5">
            <div class="w-10 h-10 rounded-lg bg-purple-600/15 flex items-center justify-center">
              <.icon name="hero-arrow-right-on-rectangle" class="size-5 text-purple-400" />
            </div>
            <div>
              <h2 class="text-lg font-semibold text-text-primary">Entrar em uma sala</h2>
              <p class="text-xs text-text-muted">Use o código ou o link que seu amigo enviou</p>
            </div>
          </div>

          <form phx-submit="join" phx-change="validate" class="space-y-3 mt-auto">
            <div>
              <input
                type="text"
                name="invite"
                value={@invite_input}
                placeholder="ABCD1234 ou https://..."
                autocomplete="off"
                autocapitalize="characters"
                autocorrect="off"
                spellcheck="false"
                enterkeyhint="go"
                inputmode="text"
                class={[
                  "w-full bg-white/5 border rounded-xl px-4 py-3 text-text-primary placeholder-text-muted/70 focus:outline-none focus:ring-2 transition-colors text-center font-mono text-base uppercase tracking-widest",
                  @error && "border-red-500 focus:ring-red-500",
                  !@error && "border-border focus:ring-purple-500"
                ]}
              />
              <p :if={@error} class="text-red-400 text-xs mt-1.5 text-center">{@error}</p>
            </div>

            <button
              type="submit"
              class="w-full inline-flex items-center justify-center gap-2 px-6 py-3 bg-purple-600 text-white font-semibold rounded-xl hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/25"
            >
              <.icon name="hero-play-solid" class="size-5" /> Entrar na Sala
            </button>
          </form>
        </div>

        <%!-- Card 2: Create --%>
        <div class="relative overflow-hidden rounded-2xl border border-purple-500/20 p-6 sm:p-8 flex flex-col bg-gradient-to-br from-purple-600/15 via-surface to-surface">
          <div
            class="absolute -top-10 -right-10 w-40 h-40 bg-purple-600/20 rounded-full blur-3xl"
            aria-hidden="true"
          />
          <div class="relative flex items-center gap-3 mb-5">
            <div class="w-10 h-10 rounded-lg bg-purple-600/20 flex items-center justify-center">
              <.icon name="hero-plus-circle" class="size-5 text-purple-300" />
            </div>
            <div>
              <h2 class="text-lg font-semibold text-text-primary">Criar nova sala</h2>
              <p class="text-xs text-text-muted">Escolha o que assistir e convide seus amigos</p>
            </div>
          </div>

          <ul class="relative space-y-2.5 text-sm text-text-secondary mb-6">
            <li class="flex items-start gap-2.5">
              <span class="mt-0.5 w-5 h-5 rounded-full bg-purple-600/25 text-purple-300 text-[11px] font-bold flex items-center justify-center flex-shrink-0">
                1
              </span>
              Abra um filme, série ou canal no catálogo
            </li>
            <li class="flex items-start gap-2.5">
              <span class="mt-0.5 w-5 h-5 rounded-full bg-purple-600/25 text-purple-300 text-[11px] font-bold flex items-center justify-center flex-shrink-0">
                2
              </span>
              Toque em <span class="font-medium text-text-primary">Watch Party</span>
              pra criar a sala
            </li>
            <li class="flex items-start gap-2.5">
              <span class="mt-0.5 w-5 h-5 rounded-full bg-purple-600/25 text-purple-300 text-[11px] font-bold flex items-center justify-center flex-shrink-0">
                3
              </span>
              Compartilhe o link ou o código com seus amigos
            </li>
          </ul>

          <.link
            navigate={~p"/browse"}
            class="relative mt-auto inline-flex items-center justify-center gap-2 px-6 py-3 bg-white/5 hover:bg-white/10 text-text-primary font-semibold rounded-xl border border-border transition-colors"
          >
            <.icon name="hero-film" class="size-5" /> Ir para o catálogo
          </.link>
        </div>
      </div>

      <%!-- Features strip --%>
      <div class="mt-10 sm:mt-14 grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
        <div class="flex items-start gap-3 p-4 rounded-xl bg-surface/50 border border-border/50">
          <.icon name="hero-bolt-solid" class="size-5 text-yellow-400 mt-0.5 flex-shrink-0" />
          <div>
            <p class="text-sm font-semibold text-text-primary">Sincronização em tempo real</p>
            <p class="text-xs text-text-muted mt-0.5">
              Play, pause e seek chegam pra todos ao mesmo tempo.
            </p>
          </div>
        </div>
        <div class="flex items-start gap-3 p-4 rounded-xl bg-surface/50 border border-border/50">
          <.icon
            name="hero-chat-bubble-left-right"
            class="size-5 text-blue-400 mt-0.5 flex-shrink-0"
          />
          <div>
            <p class="text-sm font-semibold text-text-primary">Chat ao vivo</p>
            <p class="text-xs text-text-muted mt-0.5">Converse com quem tá assistindo com você.</p>
          </div>
        </div>
        <div class="flex items-start gap-3 p-4 rounded-xl bg-surface/50 border border-border/50">
          <.icon name="hero-heart-solid" class="size-5 text-pink-400 mt-0.5 flex-shrink-0" />
          <div>
            <p class="text-sm font-semibold text-text-primary">Reações instantâneas</p>
            <p class="text-xs text-text-muted mt-0.5">
              Mande emojis que flutuam sobre o vídeo dos amigos.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
