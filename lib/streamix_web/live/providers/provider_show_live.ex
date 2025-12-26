defmodule StreamixWeb.Providers.ProviderShowLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents

  alias Streamix.Iptv

  @per_page 50

  def mount(%{"id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_user_provider(user_id, id)

    if provider do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")
      end

      categories = Iptv.list_categories(provider.id, "live")

      socket =
        socket
        |> assign(page_title: provider.name)
        |> assign(current_path: "/providers/#{id}")
        |> assign(provider: provider)
        |> assign(categories: categories)
        |> assign(selected_category: nil)
        |> assign(search: "")
        |> assign(page: 1)
        |> assign(has_more: true)
        |> assign(loading: false)
        |> assign(playing_channel: nil)
        |> assign(favorites_map: %{})
        |> stream(:channels, [])
        |> load_channels()
        |> load_favorites_map()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  def handle_params(params, _url, socket) do
    category = params["category"]
    search = params["search"] || ""

    socket =
      socket
      |> assign(selected_category: category)
      |> assign(search: search)
      |> assign(page: 1)
      |> stream(:channels, [], reset: true)
      |> load_channels()

    {:noreply, socket}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category
    provider_id = socket.assigns.provider.id

    {:noreply, push_patch(socket, to: build_path(provider_id, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    provider_id = socket.assigns.provider.id

    {:noreply,
     push_patch(socket, to: build_path(provider_id, socket.assigns.selected_category, search))}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_channels()

    {:noreply, socket}
  end

  def handle_event("play_channel", %{"id" => id}, socket) do
    channel = Iptv.get_live_channel_with_provider!(id)
    user_id = socket.assigns.current_scope.user.id

    # Add to watch history with denormalized data
    Iptv.add_watch_history(user_id, "live_channel", channel.id, %{
      content_name: channel.name,
      content_icon: channel.stream_icon
    })

    {:noreply, assign(socket, playing_channel: channel)}
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, playing_channel: nil)}
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    channel_id = String.to_integer(id)
    channel = Iptv.get_live_channel!(channel_id)

    # Toggle favorite with content_type and denormalized data
    Iptv.toggle_favorite(user_id, "live_channel", channel_id, %{
      content_name: channel.name,
      content_icon: channel.stream_icon
    })

    favorites_map =
      Map.update(socket.assigns.favorites_map, channel_id, true, fn current -> !current end)

    {:noreply, assign(socket, favorites_map: favorites_map)}
  end

  def handle_event("sync_provider", _, socket) do
    provider = socket.assigns.provider
    Iptv.async_sync_provider(provider)

    {:noreply,
     socket
     |> assign(provider: %{provider | sync_status: "pending"})
     |> put_flash(:info, "Sincronização iniciada")}
  end

  def handle_info({:sync_status, %{status: status} = payload}, socket) do
    provider = socket.assigns.provider

    updated_provider = %{
      provider
      | sync_status: status,
        live_count: Map.get(payload, :live_count, provider.live_count),
        movies_count: Map.get(payload, :movies_count, provider.movies_count),
        series_count: Map.get(payload, :series_count, provider.series_count),
        last_synced_at:
          if(status == "completed", do: DateTime.utc_now(), else: provider.last_synced_at)
    }

    socket = assign(socket, provider: updated_provider)

    if status == "completed" do
      categories = Iptv.list_categories(provider.id, "live")

      {:noreply,
       socket
       |> assign(categories: categories)
       |> assign(page: 1)
       |> stream(:channels, [], reset: true)
       |> load_channels()
       |> put_flash(
         :info,
         "Sincronização concluída! #{payload[:live_count]} canais ao vivo carregados."
       )}
    else
      {:noreply, socket}
    end
  end

  defp load_channels(socket) do
    opts =
      [
        limit: @per_page,
        offset: (socket.assigns.page - 1) * @per_page
      ]
      |> maybe_add_filter(:category_id, socket.assigns.selected_category)
      |> maybe_add_filter(:search, socket.assigns.search)

    channels = Iptv.list_live_channels(socket.assigns.provider.id, opts)
    has_more = length(channels) == @per_page

    socket
    |> stream(:channels, channels)
    |> assign(has_more: has_more)
    |> assign(loading: false)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.current_scope.user.id
    favorites = Iptv.list_favorites(user_id, content_type: "live_channel", limit: 10_000)

    favorites_map =
      favorites
      |> Enum.map(& &1.content_id)
      |> MapSet.new()
      |> Enum.into(%{}, fn id -> {id, true} end)

    assign(socket, favorites_map: favorites_map)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_path(provider_id, category, search) do
    params =
      %{}
      |> maybe_put("category", category)
      |> maybe_put("search", search)

    if params == %{} do
      ~p"/providers/#{provider_id}"
    else
      ~p"/providers/#{provider_id}?#{params}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between">
        <div>
          <.link
            navigate={~p"/providers"}
            class="text-sm text-base-content/60 hover:text-primary mb-2 inline-flex items-center gap-1"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Voltar para provedores
          </.link>
          <.header>
            {@provider.name}
            <:subtitle>
              {@provider.live_count || 0} canais ao vivo
              <span :if={@provider.movies_count && @provider.movies_count > 0} class="ml-2">
                | {@provider.movies_count} filmes
              </span>
              <span :if={@provider.series_count && @provider.series_count > 0} class="ml-2">
                | {@provider.series_count} séries
              </span>
              <span :if={@provider.last_synced_at} class="ml-2">
                - Última sinc: {format_relative_time(@provider.last_synced_at)}
              </span>
            </:subtitle>
          </.header>
        </div>
        <button
          type="button"
          phx-click="sync_provider"
          disabled={@provider.sync_status in ["pending", "syncing"]}
          class="btn btn-primary"
        >
          <.icon
            name="hero-arrow-path"
            class={["size-5", @provider.sync_status == "syncing" && "animate-spin"]}
          /> Sincronizar
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-4">
        <.category_filter_v2 categories={@categories} selected={@selected_category} />
        <.search_input value={@search} placeholder="Buscar canais ao vivo..." />
      </div>

      <div
        id="channels"
        phx-update="stream"
        class="grid gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5"
      >
        <div :for={{dom_id, channel} <- @streams.channels} id={dom_id}>
          <.live_channel_card
            channel={channel}
            is_favorite={Map.get(@favorites_map, channel.id, false)}
          />
        </div>
      </div>

      <div :if={@streams.channels == []} class="py-12">
        <.empty_state
          icon="hero-tv"
          title="Nenhum canal encontrado"
          message={
            if @provider.sync_status == "idle",
              do: "Sincronize o provedor para carregar os canais",
              else: "Tente ajustar seus filtros"
          }
        >
          <:action>
            <button
              :if={@provider.sync_status == "idle"}
              type="button"
              phx-click="sync_provider"
              class="btn btn-primary"
            >
              <.icon name="hero-arrow-path" class="size-5" /> Sincronizar Agora
            </button>
          </:action>
        </.empty_state>
      </div>

      <div
        :if={@has_more}
        id="infinite-scroll"
        phx-hook="InfiniteScroll"
        phx-viewport-bottom="load_more"
        class="flex justify-center py-8"
      >
        <.loading_spinner :if={@loading} />
      </div>

      <.video_player_v2 :if={@playing_channel} channel={@playing_channel} provider={@provider} />
    </div>
    """
  end

  defp format_relative_time(nil), do: "Nunca"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)}min atrás"
      diff < 86_400 -> "#{div(diff, 3600)}h atrás"
      true -> "#{div(diff, 86_400)}d atrás"
    end
  end
end
