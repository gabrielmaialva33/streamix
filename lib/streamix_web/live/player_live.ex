defmodule StreamixWeb.PlayerLive do
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  @impl true
  def mount(%{"id" => channel_id}, _session, socket) do
    user_id = 1

    case Iptv.get_channel(String.to_integer(channel_id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Channel not found")
         |> redirect(to: ~p"/channels")}

      channel ->
        is_favorite = Iptv.favorite?(user_id, channel.id)

        related_channels =
          Iptv.list_channels_by_group(channel.provider_id, channel.group_title, limit: 10)

        # Add to watch history
        Iptv.add_watch_history(user_id, channel.id, 0)

        {:ok,
         socket
         |> assign(:page_title, channel.name)
         |> assign(:user_id, user_id)
         |> assign(:channel, channel)
         |> assign(:is_favorite, is_favorite)
         |> assign(:related_channels, related_channels)
         |> assign(:watch_start, System.monotonic_time(:second))}
    end
  end

  @impl true
  def handle_event("toggle_favorite", _params, socket) do
    channel = socket.assigns.channel
    user_id = socket.assigns.user_id

    case Iptv.toggle_favorite(user_id, channel.id) do
      {:ok, :added} ->
        {:noreply,
         socket
         |> assign(:is_favorite, true)
         |> put_flash(:info, "Added to favorites")}

      {:ok, :removed} ->
        {:noreply,
         socket
         |> assign(:is_favorite, false)
         |> put_flash(:info, "Removed from favorites")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite")}
    end
  end

  @impl true
  def handle_event("update_duration", %{"duration" => duration}, socket) do
    # Update watch history with current duration
    # This is called periodically from the JS hook
    {:noreply, assign(socket, :last_duration, duration)}
  end

  @impl true
  def terminate(_reason, socket) do
    # Record final watch duration when leaving
    if socket.assigns[:watch_start] do
      duration = System.monotonic_time(:second) - socket.assigns.watch_start
      Iptv.add_watch_history(socket.assigns.user_id, socket.assigns.channel.id, duration)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black flex flex-col" id="player-container">
      <div class="absolute top-0 left-0 right-0 z-10 bg-gradient-to-b from-black/80 to-transparent p-4">
        <div class="flex items-center justify-between">
          <.link navigate={~p"/channels"} class="btn btn-ghost btn-circle text-white">
            <.icon name="hero-arrow-left" class="size-6" />
          </.link>

          <div class="flex items-center gap-4">
            <img
              :if={@channel.logo_url}
              src={@channel.logo_url}
              alt={@channel.name}
              class="h-10 w-10 rounded object-contain bg-white/10"
            />
            <div class="text-white">
              <h1 class="text-lg font-bold">{@channel.name}</h1>
              <p :if={@channel.group_title} class="text-sm text-white/70">{@channel.group_title}</p>
            </div>
          </div>

          <button phx-click="toggle_favorite" class="btn btn-ghost btn-circle text-white">
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class={["size-6", @is_favorite && "text-error"]}
            />
          </button>
        </div>
      </div>

      <div class="flex-1 flex items-center justify-center">
        <video
          id="video-player"
          phx-hook="HlsPlayer"
          data-stream-url={@channel.stream_url}
          class="max-h-full max-w-full"
          autoplay
          playsinline
          controls
        >
          Your browser does not support HLS streaming.
        </video>
      </div>

      <div
        :if={@related_channels != []}
        class="absolute bottom-0 left-0 right-0 z-10 bg-gradient-to-t from-black/80 to-transparent p-4"
      >
        <p class="text-white/70 text-sm mb-2">More in {@channel.group_title}</p>
        <div class="flex gap-2 overflow-x-auto pb-2">
          <.link
            :for={related <- @related_channels}
            :if={related.id != @channel.id}
            navigate={~p"/channels/#{related.id}"}
            class="flex-shrink-0 bg-white/10 hover:bg-white/20 rounded-lg p-2 transition"
          >
            <div class="w-20 h-12 bg-white/5 rounded flex items-center justify-center mb-1">
              <img
                :if={related.logo_url}
                src={related.logo_url}
                alt={related.name}
                class="max-h-full max-w-full object-contain"
              />
              <.icon :if={!related.logo_url} name="hero-tv" class="size-6 text-white/30" />
            </div>
            <p class="text-white text-xs truncate w-20">{related.name}</p>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
