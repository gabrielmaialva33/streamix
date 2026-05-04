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
      class="inline-flex items-center justify-center gap-1.5 w-full sm:w-auto px-4 sm:px-6 py-2.5 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-xs sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
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

    visible = Enum.take(users, 4)
    overflow = length(users) - length(visible)

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:overflow, overflow)
      |> assign(:total, length(users))

    ~H"""
    <div class="flex items-center gap-2">
      <div :if={@total > 0} class="flex items-center -space-x-2">
        <div
          :for={user <- @visible}
          class={[
            "relative w-9 h-9 rounded-full flex items-center justify-center text-xs font-bold ring-2 ring-black shadow-md",
            user.is_host && "bg-brand text-white",
            !user.is_host && "bg-gradient-to-br from-white/15 to-white/5 text-white"
          ]}
          title={if user.is_host, do: "#{user.email} (host)", else: user.email}
        >
          {String.first(user.email) |> String.upcase()}
          <span
            :if={user.is_host}
            class="absolute -top-0.5 -right-0.5 w-3.5 h-3.5 bg-warning rounded-full border-2 border-black flex items-center justify-center"
            title="Host"
          >
            <.icon name="hero-star-solid" class="size-2 text-black" />
          </span>
          <span
            class="absolute -bottom-0.5 -right-0.5 w-2.5 h-2.5 bg-success rounded-full border-2 border-black"
            title="Online"
          />
        </div>
        <div
          :if={@overflow > 0}
          class="relative w-9 h-9 rounded-full bg-white/10 ring-2 ring-black flex items-center justify-center text-[11px] font-semibold text-white/80"
          title="#{@overflow} mais"
        >
          +{@overflow}
        </div>
      </div>

      <div
        :if={@total > 0}
        class="hidden sm:inline-flex items-center gap-1 text-[11px] text-white/60 font-medium"
      >
        <span class="relative flex w-1.5 h-1.5">
          <span class="absolute inline-flex w-full h-full rounded-full bg-success opacity-75 animate-ping">
          </span>
          <span class="relative inline-flex w-1.5 h-1.5 rounded-full bg-success"></span>
        </span>
        {@total} {if @total == 1, do: "online", else: "online"}
      </div>

      <div :if={@total == 0} class="text-white/50 text-xs">
        Sozinho na sala
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
      class="group inline-flex items-center gap-1.5 pl-2 pr-2.5 py-1.5 rounded-full bg-white/10 text-white/90 text-xs hover:bg-white/20 backdrop-blur-sm transition-colors cursor-pointer border border-white/10 hover:border-white/20"
      title="Copiar link de convite"
    >
      <span class="w-5 h-5 rounded-full bg-brand/20 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-link" class="size-3 text-brand" />
      </span>
      <span class="font-mono font-semibold tracking-widest">{String.upcase(@invite_code)}</span>
      <.icon
        name="hero-clipboard-document"
        class="size-3.5 text-white/50 group-hover:text-white transition-colors"
      />
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
    <%!-- Mobile: tap outside closes. Desktop: sidebar pinned right, no overlay. --%>
    <div
      phx-click="toggle_chat"
      class="fixed inset-0 z-40 bg-black/40 backdrop-blur-[1px] sm:hidden"
      aria-hidden="true"
    />
    <%!--
      Mobile: slide up from the bottom as a 80dvh bottom sheet so the user
      still sees the video above the chat.
      Desktop (sm+): pinned right sidebar, full-height 320px wide.
    --%>
    <aside class="fixed z-50 bg-surface/95 backdrop-blur-md flex flex-col shadow-modal
                  inset-x-0 bottom-0 h-[80dvh] rounded-t-lg border-t border-border
                  sm:inset-auto sm:top-0 sm:right-0 sm:bottom-0 sm:h-full sm:w-80 sm:rounded-none sm:border-t-0 sm:border-l sm:border-border">
      <%!-- Mobile grip handle — affordance that the sheet can be dismissed. --%>
      <div class="sm:hidden pt-2 pb-1 flex justify-center flex-shrink-0">
        <div class="w-10 h-1 rounded-full bg-white/20" aria-hidden="true" />
      </div>
      <%!-- Header --%>
      <div class="px-4 py-3 border-b border-border/60 flex items-center justify-between bg-surface-elevated">
        <div class="flex items-center gap-2">
          <div class="w-8 h-8 rounded-lg bg-brand/15 flex items-center justify-center">
            <.icon name="hero-chat-bubble-left-right" class="size-4 text-brand" />
          </div>
          <div>
            <h3 class="text-text-primary font-semibold text-sm leading-tight">Chat</h3>
            <p class="text-[11px] text-text-muted leading-tight">em tempo real</p>
          </div>
        </div>
        <button
          phx-click="toggle_chat"
          class="p-1.5 rounded-lg text-text-muted hover:text-text-primary hover:bg-surface-hover transition-colors focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label="Fechar chat"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <%!-- Messages --%>
      <div
        id="wp-chat-messages"
        phx-update="stream"
        class="flex-1 overflow-y-auto px-3 py-4 space-y-3 scrollbar-thin"
      >
        <div :for={{dom_id, message} <- @messages} id={dom_id} class="group">
          <%!-- Text messages render as a compact bubble with avatar initial --%>
          <div :if={message.type == "text"} class="flex items-start gap-2">
            <div class="w-7 h-7 rounded-full bg-brand text-white text-[11px] font-bold flex items-center justify-center flex-shrink-0 mt-0.5">
              {message.user.email |> String.first() |> String.upcase()}
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline gap-1.5">
                <span class="font-semibold text-xs text-brand truncate">
                  {message.user.email |> String.split("@") |> hd()}
                </span>
              </div>
              <p class="text-sm text-text-primary leading-snug break-words">{message.content}</p>
            </div>
          </div>

          <%!-- Reactions sit inline, a little bigger, centered --%>
          <div :if={message.type == "reaction"} class="flex justify-center text-2xl py-0.5">
            {message.content}
          </div>

          <%!-- System messages: small muted pill, centered --%>
          <div :if={message.type == "system"} class="flex justify-center">
            <span class="text-[11px] text-text-muted italic px-2.5 py-1 rounded-full bg-white/5 border border-border/30">
              {message.content}
            </span>
          </div>
        </div>
      </div>

      <%!-- Reaction bar --%>
      <div class="px-3 py-2 border-t border-border/60 flex items-center gap-0.5 justify-between bg-black/20">
        <button
          :for={emoji <- ~w(👍 ❤️ 😂 😮 😢 🔥)}
          type="button"
          phx-click="send_reaction"
          phx-value-emoji={emoji}
          class="w-10 h-10 rounded-lg text-xl flex items-center justify-center hover:bg-surface-hover hover:scale-110 active:scale-95 transition-all focus:outline-none focus:ring-2 focus:ring-brand"
          aria-label="Enviar reação"
        >
          {emoji}
        </button>
      </div>

      <%!-- Message input — pb respects iOS home-indicator safe area. --%>
      <form
        phx-submit="send_message"
        class="p-3 border-t border-border/60"
        style="padding-bottom: max(0.75rem, calc(0.75rem + env(safe-area-inset-bottom)))"
      >
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
            placeholder="Digite uma mensagem..."
            autocomplete="off"
            enterkeyhint="send"
            class="flex-1 bg-surface border border-border rounded-lg px-4 py-2 text-sm text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-brand focus:border-transparent transition-colors"
          />
          <button
            type="submit"
            aria-label="Enviar mensagem"
            class="w-10 h-10 rounded-lg bg-brand flex items-center justify-center text-white hover:bg-brand-hover active:scale-95 transition-all shadow-card focus:outline-none focus:ring-2 focus:ring-brand"
          >
            <.icon name="hero-paper-airplane-solid" class="size-4" />
          </button>
        </div>
      </form>
    </aside>
    """
  end
end
