defmodule StreamixWeb.SettingsLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(_params, _session, socket) do
    user_id = 1

    stats = %{
      history_count: length(Iptv.list_watch_history(user_id, limit: 10_000)),
      favorites_count: Iptv.count_favorites(user_id)
    }

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:user_id, user_id)
     |> assign(:stats, stats)}
  end

  @impl true
  def handle_event("clear_history", _params, socket) do
    case Iptv.clear_watch_history(socket.assigns.user_id) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> update(:stats, &Map.put(&1, :history_count, 0))
         |> put_flash(:info, "Watch history cleared")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to clear history")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Settings
      </.header>

      <div class="space-y-6 max-w-2xl">
        <.card title="Appearance">
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Theme</p>
              <p class="text-sm text-base-content/60">Choose your preferred theme</p>
            </div>
            <Layouts.theme_toggle />
          </div>
        </.card>

        <.card title="Data">
          <div class="space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium">Watch History</p>
                <p class="text-sm text-base-content/60">{@stats.history_count} entries</p>
              </div>
              <button
                phx-click="clear_history"
                data-confirm="Are you sure you want to clear all watch history?"
                class="btn btn-sm btn-error"
                disabled={@stats.history_count == 0}
              >
                Clear
              </button>
            </div>

            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium">Favorites</p>
                <p class="text-sm text-base-content/60">{@stats.favorites_count} channels</p>
              </div>
              <.link navigate={~p"/favorites"} class="btn btn-sm btn-ghost">
                View
              </.link>
            </div>
          </div>
        </.card>

        <.card title="About">
          <div class="space-y-2 text-sm text-base-content/70">
            <p><strong>Streamix</strong> - IPTV Streaming Application</p>
            <p>Built with Phoenix LiveView</p>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
