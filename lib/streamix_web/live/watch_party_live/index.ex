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
    <div class="flex items-center justify-center min-h-[70vh]">
      <div class="w-full max-w-md mx-4">
        <div class="text-center mb-8">
          <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-purple-600/20 mb-4">
            <.icon name="hero-users" class="size-8 text-purple-400" />
          </div>
          <h1 class="text-2xl font-bold text-text-primary">Watch Party</h1>
          <p class="text-text-secondary mt-2">
            Assista junto com amigos em tempo real
          </p>
        </div>

        <div class="bg-surface rounded-2xl border border-border p-6 space-y-6">
          <div>
            <h2 class="text-lg font-semibold text-text-primary mb-1">Entrar em uma sala</h2>
            <p class="text-sm text-text-muted">Cole o link de convite ou digite o código da sala</p>
          </div>

          <form phx-submit="join" phx-change="validate" class="space-y-4">
            <div>
              <input
                type="text"
                name="invite"
                value={@invite_input}
                placeholder="Código da sala ou link de convite"
                autocomplete="off"
                autofocus
                class={[
                  "w-full bg-white/5 border rounded-xl px-4 py-3 text-text-primary placeholder-text-muted focus:outline-none focus:ring-2 transition-colors text-center font-mono text-lg uppercase tracking-widest",
                  @error && "border-red-500 focus:ring-red-500",
                  !@error && "border-border focus:ring-purple-500"
                ]}
              />
              <p :if={@error} class="text-red-400 text-xs mt-1.5 text-center">{@error}</p>
            </div>

            <button
              type="submit"
              class="w-full px-6 py-3 bg-purple-600 text-white font-bold rounded-xl hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/20 text-base"
            >
              Entrar na Sala
            </button>
          </form>

          <div class="relative">
            <div class="absolute inset-0 flex items-center">
              <div class="w-full border-t border-border" />
            </div>
            <div class="relative flex justify-center text-xs">
              <span class="px-3 bg-surface text-text-muted">ou</span>
            </div>
          </div>

          <p class="text-center text-sm text-text-secondary">
            Para criar uma sala, vá até um filme ou episódio e clique em
            <span class="text-purple-400 font-medium">Watch Party</span>
          </p>
        </div>
      </div>
    </div>
    """
  end
end
