defmodule StreamixWeb.WatchPartyComponents do
  @moduledoc """
  UI components for Watch Party.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  @doc """
  Button to create a Watch Party from content detail pages.
  """
  attr :content_type, :string, required: true
  attr :content_id, :any, required: true

  def create_party_button(assigns) do
    ~H"""
    <.link
      navigate={~p"/party/new/#{@content_type}/#{@content_id}"}
      class="inline-flex items-center justify-center gap-1.5 w-full sm:w-auto px-4 sm:px-6 py-2.5 sm:py-3.5 bg-purple-600 text-white font-bold rounded-lg hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/30 text-xs sm:text-base"
    >
      <.icon name="hero-users" class="size-4 sm:size-5" /> Watch Party
    </.link>
    """
  end

  @doc """
  Presence indicators — circular avatars with host badge.
  """
  attr :presences, :map, required: true

  def presence_indicators(assigns) do
    users =
      assigns.presences
      |> Enum.map(fn {_key, %{metas: [meta | _]}} -> meta end)
      |> Enum.sort_by(& &1.joined_at)

    assigns = assign(assigns, :users, users)

    ~H"""
    <div class="flex items-center -space-x-2">
      <div
        :for={user <- @users}
        class={[
          "relative w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold border-2 border-black",
          user.is_host && "bg-purple-600 text-white",
          !user.is_host && "bg-white/20 text-white"
        ]}
        title={user.email}
      >
        {String.first(user.email) |> String.upcase()}
        <div
          :if={user.is_host}
          class="absolute -top-1 -right-1 w-3 h-3 bg-yellow-400 rounded-full border border-black"
          title="Host"
        />
      </div>
      <div
        :if={length(@users) == 0}
        class="text-white/50 text-xs"
      >
        Nenhum participante
      </div>
    </div>
    """
  end

  @doc """
  Copiable invite code badge.
  """
  attr :invite_code, :string, required: true

  def invite_badge(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        Phoenix.LiveView.JS.dispatch("phx:copy", detail: %{text: url(~p"/party/#{@invite_code}")})
      }
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-white/10 text-white/70 text-xs hover:bg-white/20 transition-colors cursor-pointer"
      title="Copiar link"
    >
      <.icon name="hero-link-micro" class="size-3" />
      <span class="font-mono tracking-wider">{String.upcase(@invite_code)}</span>
    </button>
    """
  end

  @doc """
  Chat sidebar with messages and reaction bar.
  """
  attr :messages, :list, required: true
  attr :message_input, :string, default: ""
  attr :room_id, :integer, required: true

  def chat_sidebar(assigns) do
    ~H"""
    <div class="w-80 bg-surface/95 backdrop-blur-sm border-l border-border flex flex-col h-full">
      <%!-- Header --%>
      <div class="p-3 border-b border-border flex items-center justify-between">
        <h3 class="text-text-primary font-semibold text-sm">Chat</h3>
        <button phx-click="toggle_chat" class="text-text-muted hover:text-text-secondary">
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>

      <%!-- Messages --%>
      <div
        id="wp-chat-messages"
        phx-update="stream"
        class="flex-1 overflow-y-auto p-3 space-y-2 scrollbar-thin"
      >
        <div :for={{dom_id, message} <- @messages} id={dom_id} class="group">
          <div :if={message.type == "text"} class="text-sm">
            <span class="font-medium text-purple-400">
              {message.user.email |> String.split("@") |> hd()}
            </span>
            <span class="text-text-secondary ml-1">{message.content}</span>
          </div>
          <div :if={message.type == "reaction"} class="text-2xl">
            {message.content}
          </div>
          <div :if={message.type == "system"} class="text-xs text-text-muted italic text-center">
            {message.content}
          </div>
        </div>
      </div>

      <%!-- Reaction bar --%>
      <div class="px-3 py-2 border-t border-border flex items-center gap-1 justify-center">
        <button
          :for={emoji <- ~w(👍 ❤️ 😂 😮 😢 🔥)}
          type="button"
          phx-click="send_reaction"
          phx-value-emoji={emoji}
          class="text-xl hover:scale-125 transition-transform cursor-pointer"
        >
          {emoji}
        </button>
      </div>

      <%!-- Message input --%>
      <form phx-submit="send_message" class="p-3 border-t border-border">
        <div class="flex gap-2">
          <%!--
            iOS Safari: enterkeyhint="send" swaps Return for "Send" on the
            on-screen keyboard, which matches what the button does. Chat
            messages should keep autocapitalize + autocorrect on (user text).
          --%>
          <input
            type="text"
            name="message"
            value={@message_input}
            placeholder="Enviar mensagem..."
            autocomplete="off"
            enterkeyhint="send"
            class="flex-1 bg-white/5 border border-border rounded-lg px-3 py-2 text-sm text-text-primary placeholder-text-muted focus:outline-none focus:ring-1 focus:ring-purple-500"
          />
          <button
            type="submit"
            class="p-2 bg-purple-600 rounded-lg text-white hover:bg-purple-700 transition-colors"
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
          </button>
        </div>
      </form>
    </div>
    """
  end
end
