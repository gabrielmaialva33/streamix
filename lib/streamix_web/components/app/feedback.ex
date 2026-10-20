defmodule StreamixWeb.App.Feedback do
  @moduledoc """
  Empty and loading feedback components.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :cta_label, :string, default: "Explorar catálogo"
  attr :cta_navigate, :string, default: "/browse"
  attr :class, :any, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      data-empty-state
      class={[
        "flex flex-col items-center justify-center rounded-2xl border border-border bg-surface/40 px-4 py-12 text-center sm:py-16",
        @class
      ]}
    >
      <div class="mb-4 rounded-full bg-surface-hover p-5">
        <.icon name={@icon} class="size-10 text-text-muted" />
      </div>
      <h3 class="mb-1 text-lg font-semibold text-text-primary">{@title}</h3>
      <p :if={@message} class="mb-6 max-w-md text-sm text-text-secondary">{@message}</p>
      {render_slot(@action)}
      <.button
        :if={@action == [] and is_binary(@cta_navigate) and @cta_navigate != ""}
        navigate={@cta_navigate}
        variant="secondary"
        data-empty-cta
      >
        {@cta_label}
      </.button>
    </div>
    """
  end

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

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :sync_page_url, :boolean, default: false
  attr :stream_target, :string, default: nil
  attr :auto_loads, :integer, default: nil
  attr :label, :string, default: "Carregar mais"
  attr :class, :any, default: nil

  @doc "Renders controlled infinite scroll with an accessible manual fallback."
  def infinite_scroll_sentinel(assigns) do
    controls_id =
      case assigns.stream_target do
        "#" <> id -> id
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    assigns = assign(assigns, :controls_id, controls_id)

    ~H"""
    <div
      id={@id}
      phx-hook="InfiniteScroll"
      data-page={@page}
      data-sync-page-url={to_string(@sync_page_url)}
      data-stream-target={@stream_target}
      data-auto-loads={@auto_loads}
      class={["flex min-h-16 items-center justify-center py-2", @class]}
    >
      <button
        type="button"
        phx-click="load_more"
        phx-disable-with="Carregando..."
        data-infinite-scroll-manual
        aria-controls={@controls_id}
        hidden
        class="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg border border-border bg-surface px-5 py-2 text-sm font-medium text-text-primary transition-colors hover:bg-surface-hover focus:outline-none focus:ring-2 focus:ring-brand disabled:cursor-wait disabled:opacity-70"
      >
        <.icon name="hero-chevron-down" class="size-4" />
        <span data-infinite-scroll-label>{@label}</span>
      </button>
      <span data-infinite-scroll-status class="sr-only" aria-live="polite"></span>
    </div>
    """
  end
end
