defmodule StreamixWeb.DashboardLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(_params, _session, socket) do
    # Hardcoded until auth is implemented
    user_id = 1

    stats = get_stats(user_id)
    providers = Iptv.list_providers(user_id)
    recent_history = Iptv.list_watch_history(user_id, limit: 5)

    # Subscribe to provider sync updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user_id}:providers")
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:user_id, user_id)
     |> assign(:stats, stats)
     |> assign(:providers, providers)
     |> assign(:recent_history, recent_history)}
  end

  @impl true
  def handle_info({:sync_status, %{provider_id: provider_id, status: status}}, socket) do
    providers =
      Enum.map(socket.assigns.providers, fn provider ->
        if provider.id == provider_id do
          %{provider | sync_status: status}
        else
          provider
        end
      end)

    # Refresh stats if sync completed
    stats =
      if status == "completed" do
        get_stats(socket.assigns.user_id)
      else
        socket.assigns.stats
      end

    {:noreply, assign(socket, providers: providers, stats: stats)}
  end

  @impl true
  def handle_event("sync_all", _params, socket) do
    Enum.each(socket.assigns.providers, fn provider ->
      Iptv.sync_provider_async(provider)
    end)

    {:noreply, put_flash(socket, :info, "Syncing all providers...")}
  end

  defp get_stats(user_id) do
    providers = Iptv.list_providers(user_id)
    total_channels = Enum.reduce(providers, 0, fn p, acc -> acc + (p.channels_count || 0) end)

    %{
      providers: length(providers),
      channels: total_channels,
      favorites: Iptv.count_favorites(user_id),
      watch_time: format_watch_time(Iptv.total_watch_time(user_id))
    }
  end

  defp format_watch_time(seconds) when is_integer(seconds) and seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "< 1m"
    end
  end

  defp format_watch_time(_), do: "0m"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil}>
      <.header>
        Dashboard
        <:actions>
          <button
            :if={@providers != []}
            phx-click="sync_all"
            class="btn btn-sm btn-primary"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Sync All
          </button>
        </:actions>
      </.header>

      <div class="stats shadow w-full bg-base-200 mb-6">
        <.stat_item title="Providers" value={@stats.providers} icon="hero-server" />
        <.stat_item title="Channels" value={@stats.channels} icon="hero-tv" />
        <.stat_item title="Favorites" value={@stats.favorites} icon="hero-heart" />
        <.stat_item title="Watch Time" value={@stats.watch_time} icon="hero-clock" />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <.card title="Recent Activity">
          <div :if={@recent_history == []} class="text-center py-8 text-base-content/60">
            No watch history yet
          </div>
          <div :if={@recent_history != []} class="divide-y divide-base-300">
            <.history_entry :for={entry <- @recent_history} entry={entry} />
          </div>
        </.card>

        <.card title="Providers">
          <:actions>
            <.link navigate={~p"/providers/new"} class="btn btn-xs btn-ghost">
              <.icon name="hero-plus" class="size-4" /> Add
            </.link>
          </:actions>

          <div :if={@providers == []} class="text-center py-8">
            <.icon name="hero-server" class="size-12 text-base-content/30 mx-auto mb-2" />
            <p class="text-base-content/60">No providers configured</p>
            <.link navigate={~p"/providers/new"} class="btn btn-primary btn-sm mt-4">
              Add Provider
            </.link>
          </div>

          <div :if={@providers != []} class="space-y-3">
            <div
              :for={provider <- @providers}
              class="flex items-center justify-between p-3 bg-base-300 rounded-lg"
            >
              <div>
                <p class="font-medium">{provider.name}</p>
                <p class="text-sm text-base-content/60">
                  {provider.channels_count || 0} channels
                </p>
              </div>
              <.sync_status_badge status={provider.sync_status} />
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
