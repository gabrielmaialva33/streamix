defmodule StreamixWeb.Content.LiveChannelsLive do
  @moduledoc """
  LiveView for browsing live channels from a provider.
  Works for both /browse (global provider) and /providers/:id (user provider).
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Iptv

  @per_page 50

  # Mount for /browse (global provider)
  def mount(%{}, _session, socket) when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_global_provider()

    if provider do
      mount_with_provider(socket, provider, user_id, :browse)
    else
      {:ok,
       socket
       |> put_flash(:error, "Catálogo não disponível. Configure um provedor.")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  # Mount for /providers/:provider_id (user provider)
  def mount(%{"provider_id" => provider_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_playable_provider(user_id, provider_id)

    if provider do
      mount_with_provider(socket, provider, user_id, :provider)
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  defp mount_with_provider(socket, provider, user_id, mode) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")
      # Trigger async EPG sync if needed
      maybe_sync_epg(provider)
    end

    user = socket.assigns.current_scope.user
    categories = Iptv.list_categories(provider.id, "live")
    categories = filter_adult_categories(categories, user.show_adult_content)

    current_path =
      if mode == :browse,
        do: "/browse",
        else: "/providers/#{provider.id}"

    page_title =
      if mode == :browse,
        do: "Ao Vivo",
        else: "#{provider.name} - Ao Vivo"

    socket =
      socket
      |> assign(page_title: page_title)
      |> assign(current_path: current_path)
      |> assign(provider: provider)
      |> assign(mode: mode)
      |> assign(categories: categories)
      |> assign(selected_category: nil)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: true)
      |> assign(loading: false)
      |> assign(playing_channel: nil)
      |> assign(favorites_map: %{})
      |> assign(empty_results: false)
      |> assign(user_id: user_id)
      |> assign(epg_syncing: false)
      |> stream(:channels, [])
      |> load_favorites_map()

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    category = parse_integer_param(params["category"])
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

  defp parse_integer_param(nil), do: nil
  defp parse_integer_param(""), do: nil
  defp parse_integer_param(value) when is_binary(value), do: String.to_integer(value)
  defp parse_integer_param(value), do: value

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category
    {:noreply, push_patch(socket, to: build_path(socket, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket, to: build_path(socket, socket.assigns.selected_category, search))}
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
    user_id = socket.assigns.user_id

    Iptv.add_watch_history(user_id, "live_channel", channel.id, %{
      content_name: channel.name,
      content_icon: channel.stream_icon
    })

    {:noreply, assign(socket, playing_channel: channel)}
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, playing_channel: nil)}
  end

  # Player hook events - ignore silently as they're handled by the JS player
  def handle_event("player_initializing", _params, socket), do: {:noreply, socket}
  def handle_event("update_watch_time", _params, socket), do: {:noreply, socket}
  def handle_event("player_error", _params, socket), do: {:noreply, socket}
  def handle_event("buffering", _params, socket), do: {:noreply, socket}
  def handle_event("streaming_mode_changed", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id
    channel_id = String.to_integer(id)
    channel = Iptv.get_live_channel!(channel_id)

    Iptv.toggle_favorite(user_id, "live_channel", channel_id, %{
      content_name: channel.name,
      content_icon: channel.stream_icon
    })

    # Toggle in MapSet
    favorites_map =
      if MapSet.member?(socket.assigns.favorites_map, channel_id) do
        MapSet.delete(socket.assigns.favorites_map, channel_id)
      else
        MapSet.put(socket.assigns.favorites_map, channel_id)
      end

    {:noreply,
     socket
     |> assign(favorites_map: favorites_map)
     |> stream_insert(:channels, channel)}
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
        live_channels_count: Map.get(payload, :live_channels_count, provider.live_channels_count),
        movies_count: Map.get(payload, :movies_count, provider.movies_count),
        series_count: Map.get(payload, :series_count, provider.series_count),
        live_synced_at:
          if(status == "completed", do: DateTime.utc_now(), else: provider.live_synced_at)
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
       |> put_flash(:info, "Sincronização concluída!")}
    else
      {:noreply, socket}
    end
  end

  # Handler for EPG sync completion - refresh channel list to show EPG data
  def handle_info({:epg_sync_complete, :ok}, socket) do
    # Reload channels to pick up EPG data
    socket =
      socket
      |> assign(page: 1)
      |> stream(:channels, [], reset: true)
      |> load_channels()

    {:noreply, socket}
  end

  def handle_info({:epg_sync_complete, _}, socket) do
    # EPG sync failed or was not needed, just ignore
    {:noreply, socket}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center gap-4">
        <%= if @mode == :browse do %>
          <.source_tabs selected="iptv" path="/browse" gindex_path="/browse/movies" />
          <div class="hidden sm:block w-px h-8 bg-border" />
          <.browse_tabs
            selected={:live}
            source="iptv"
            counts={
              %{
                live: @provider.live_channels_count,
                movies: @provider.movies_count,
                series: @provider.series_count
              }
            }
          />
        <% else %>
          <.content_tabs
            selected={:live}
            provider_id={@provider.id}
            counts={
              %{
                live: @provider.live_channels_count,
                movies: @provider.movies_count,
                series: @provider.series_count
              }
            }
          />
        <% end %>

        <.category_filter_v2 categories={@categories} selected={@selected_category} />
        <.search_input value={@search} placeholder="Buscar canais ao vivo..." />

        <%= if @mode == :provider do %>
          <div class="ml-auto">
            <button
              type="button"
              phx-click="sync_provider"
              disabled={@provider.sync_status in ["pending", "syncing"]}
              class="inline-flex items-center gap-2 px-3 py-2 text-sm bg-surface hover:bg-surface-hover border border-border text-text-primary font-medium rounded-lg disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              title={"Última sinc: #{format_relative_time(@provider.live_synced_at)}"}
            >
              <.icon
                name="hero-arrow-path"
                class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
              />
              <span class="hidden sm:inline">Sincronizar</span>
            </button>
          </div>
        <% end %>
      </div>

      <div
        id="channels"
        phx-update="stream"
        class="grid gap-2 sm:gap-4 grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5"
      >
        <div :for={{dom_id, channel} <- @streams.channels} id={dom_id}>
          <.live_channel_card
            channel={channel}
            is_favorite={MapSet.member?(@favorites_map, channel.id)}
          />
        </div>
      </div>

      <div :if={@empty_results} class="py-12">
        <.empty_state
          icon="hero-tv"
          title="Nenhum canal encontrado"
          message={empty_message(@mode, @provider.sync_status)}
        >
          <:action>
            <button
              :if={@mode == :provider && @provider.sync_status == "idle"}
              type="button"
              phx-click="sync_provider"
              class="inline-flex items-center gap-2 px-4 py-2 bg-brand text-white font-medium rounded-lg hover:bg-brand-hover transition-colors"
            >
              <.icon name="hero-arrow-path" class="size-5" /> Sincronizar Agora
            </button>
          </:action>
        </.empty_state>
      </div>

      <.infinite_scroll has_more={@has_more} loading={@loading} />

      <.video_player_v2 :if={@playing_channel} channel={@playing_channel} provider={@provider} />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp load_channels(socket) do
    user = socket.assigns.current_scope.user

    opts =
      [
        limit: @per_page,
        offset: (socket.assigns.page - 1) * @per_page,
        show_adult: user.show_adult_content
      ]
      |> maybe_add_filter(:category_id, socket.assigns.selected_category)
      |> maybe_add_filter(:search, socket.assigns.search)

    provider = socket.assigns.provider
    channels = Iptv.list_live_channels(provider.id, opts)

    # Enrich channels with EPG data
    channels = Iptv.enrich_channels_with_epg(channels, provider.id)

    has_more = length(channels) == @per_page
    empty_results = socket.assigns.page == 1 && Enum.empty?(channels)

    socket
    |> stream(:channels, channels)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_favorites_map(socket) do
    user_id = socket.assigns.user_id
    # Optimized: only fetches content_ids instead of full records
    favorite_ids = Iptv.list_favorite_ids(user_id, "live_channel")
    assign(socket, favorites_map: favorite_ids)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  # Path builders based on mode
  defp build_path(%{assigns: %{mode: :browse}}, nil, ""), do: ~p"/browse"
  defp build_path(%{assigns: %{mode: :browse}}, nil, search), do: ~p"/browse?search=#{search}"

  defp build_path(%{assigns: %{mode: :browse}}, category, ""),
    do: ~p"/browse?category=#{category}"

  defp build_path(%{assigns: %{mode: :browse}}, category, search),
    do: ~p"/browse?category=#{category}&search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}?search=#{search}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}?category=#{category}"

  defp build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}?category=#{category}&search=#{search}"

  defp empty_message(:provider, "idle"), do: "Sincronize o provedor para carregar os canais"
  defp empty_message(_, _), do: "Tente ajustar seus filtros"

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

  # EPG sync helper - triggers async sync if EPG data is stale
  defp maybe_sync_epg(provider) do
    pid = self()

    Task.start(fn ->
      # Get channels for this provider to sync EPG
      channels = Iptv.list_live_channels(provider.id, limit: 100)
      result = Iptv.ensure_epg_available(provider, channels)
      send(pid, {:epg_sync_complete, result})
    end)
  end
end
