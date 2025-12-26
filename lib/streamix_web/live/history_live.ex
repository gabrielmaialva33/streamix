defmodule StreamixWeb.HistoryLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(_params, _session, socket) do
    user_id = 1
    history = Iptv.list_watch_history(user_id, limit: 50)

    {:ok,
     socket
     |> assign(:page_title, "Watch History")
     |> assign(:user_id, user_id)
     |> stream(:history, history)}
  end

  @impl true
  def handle_event("clear_history", _params, socket) do
    user_id = socket.assigns.user_id

    case Iptv.clear_watch_history(user_id) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> stream(:history, [], reset: true)
         |> put_flash(:info, "Watch history cleared")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to clear history")}
    end
  end

  @impl true
  def handle_event("remove_entry", %{"id" => _entry_id}, socket) do
    # For now, we don't have a function to remove a single entry
    # This would need to be added to the Iptv context
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Watch History
        <:actions>
          <button
            phx-click="clear_history"
            data-confirm="Are you sure you want to clear all watch history?"
            class="btn btn-sm btn-error"
          >
            <.icon name="hero-trash" class="size-4" /> Clear All
          </button>
        </:actions>
      </.header>

      <div id="history-list" phx-update="stream" class="divide-y divide-base-300">
        <.history_entry
          :for={{dom_id, entry} <- @streams.history}
          id={dom_id}
          entry={entry}
        />
      </div>

      <.empty_state
        :if={Enum.empty?(@streams.history |> Enum.to_list())}
        icon="hero-clock"
        title="No watch history"
        description="Start watching channels to build your history"
      >
        <:actions>
          <.link navigate={~p"/channels"} class="btn btn-primary">
            Browse Channels
          </.link>
        </:actions>
      </.empty_state>
    </Layouts.app>
    """
  end
end
