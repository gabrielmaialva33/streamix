defmodule StreamixWeb.Content.LiveChannelsLive do
  @moduledoc """
  LiveView for browsing live channels from a provider.
  Works for both /browse (global provider) and /providers/:id (user provider).
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Access
  alias Streamix.Iptv

  @per_page 50

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    user_id = user.id

    socket =
      socket
      |> assign(page_title: "Ao Vivo")
      |> assign(current_path: "/browse")
      |> assign(provider: nil)
      |> assign(mode: :browse)
      |> assign(premium_access: premium_access?(user))
      |> assign(categories: [])
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

    case apply_route_context(socket, params) do
      {:ok, socket} ->
        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(page: 1)
          |> stream(:channels, [], reset: true)
          |> load_channels()

        {:noreply, socket}

      {:redirect, socket} ->
        {:noreply, socket}
    end
  end

  defp parse_integer_param(nil), do: nil
  defp parse_integer_param(""), do: nil

  defp parse_integer_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer_param(value), do: value

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

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
    with channel_id when is_integer(channel_id) <- parse_integer_param(id),
         channel <- Iptv.get_live_channel_with_provider!(channel_id) do
      user_id = socket.assigns.user_id

      Iptv.add_watch_history(user_id, "live_channel", channel.id, %{
        content_name: channel.name,
        content_icon: channel.stream_icon
      })

      {:noreply, assign(socket, playing_channel: channel)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, playing_channel: nil)}
  end

  # Player hook events - ignore silently as they're handled by the JS player
  def handle_event("progress_update", _params, socket), do: {:noreply, socket}
  def handle_event("player_initializing", _params, socket), do: {:noreply, socket}
  def handle_event("device_diagnostics", _params, socket), do: {:noreply, socket}
  def handle_event("update_watch_time", _params, socket), do: {:noreply, socket}
  def handle_event("player_error", _params, socket), do: {:noreply, socket}
  def handle_event("player_debug", _params, socket), do: {:noreply, socket}
  def handle_event("diagnostic_suggestion", _params, socket), do: {:noreply, socket}
  def handle_event("codec_abr_suggestion", _params, socket), do: {:noreply, socket}
  def handle_event("buffering", _params, socket), do: {:noreply, socket}
  def handle_event("streaming_mode_changed", _params, socket), do: {:noreply, socket}
  def handle_event("qualities_available", _params, socket), do: {:noreply, socket}
  def handle_event("quality_changed", _params, socket), do: {:noreply, socket}
  def handle_event("quality_switched", _params, socket), do: {:noreply, socket}
  def handle_event("audio_tracks_available", _params, socket), do: {:noreply, socket}
  def handle_event("subtitle_tracks_available", _params, socket), do: {:noreply, socket}
  def handle_event("audio_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("subtitle_track_changed", _params, socket), do: {:noreply, socket}
  def handle_event("duration_available", _params, socket), do: {:noreply, socket}
  def handle_event("playback_rate_changed", _params, socket), do: {:noreply, socket}
  def handle_event("mute_toggled", _params, socket), do: {:noreply, socket}
  def handle_event("volume_changed", _params, socket), do: {:noreply, socket}
  def handle_event("pip_toggled", _params, socket), do: {:noreply, socket}
  def handle_event("pip_error", _params, socket), do: {:noreply, socket}
  def handle_event("request_token_refresh", _params, socket), do: {:noreply, socket}
  def handle_event("avplayer_preference_changed", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id
    channel_id = parse_integer_param(id)

    if is_nil(channel_id) do
      {:noreply, socket}
    else
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

  # Handler for EPG sync completion (from Oban worker via PubSub)
  def handle_info({:epg_sync_complete, :ok, _results}, socket) do
    # Reload channels to pick up EPG data
    socket =
      socket
      |> assign(page: 1)
      |> assign(epg_syncing: false)
      |> stream(:channels, [], reset: true)
      |> load_channels()

    {:noreply, socket}
  end

  def handle_info({:epg_sync_complete, _, _}, socket) do
    # EPG sync failed, just update status
    {:noreply, assign(socket, epg_syncing: false)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="space-y-4 sm:space-y-5">
      <div class="browse-toolbar">
        <%!-- Row 1: Source toggle + Content tabs --%>
        <div class="browse-toolbar__row">
          <%= if @mode == :browse do %>
            <.source_tabs selected="iptv" path="/browse" gindex_path="/browse/movies" />
            <div class="browse-toolbar__divider" />
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

          <.search_input
            value={@search}
            placeholder="Buscar canais..."
            class="browse-toolbar__search"
          />
          <%= if @mode == :provider do %>
            <button
              type="button"
              phx-click="sync_provider"
              disabled={@provider.sync_status in ["pending", "syncing"]}
              class="segmented-control__item flex-shrink-0"
              title={"Última sinc: #{format_relative_time(@provider.live_synced_at)}"}
            >
              <.icon
                name="hero-arrow-path"
                class={["size-4", @provider.sync_status == "syncing" && "animate-spin"]}
              />
              <span class="hidden sm:inline">Sincronizar</span>
            </button>
          <% end %>
        </div>

        <.premium_cta_banner
          :if={@mode == :browse and not @premium_access}
          id="browse-premium-cta"
          current_scope={@current_scope}
        />
      </div>

      <div class="flex flex-col sm:flex-row gap-4 sm:gap-6">
        <.category_filter_v2
          categories={@categories}
          selected={@selected_category}
          layout={:sidebar}
        />
        <div class="flex-1 min-w-0">
          <div
            id="channels"
            phx-update="stream"
            class="grid gap-3 sm:gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
          >
            <div :for={{dom_id, channel} <- @streams.channels} id={dom_id}>
              <.live_channel_card
                channel={channel}
                is_favorite={MapSet.member?(@favorites_map, channel.id)}
              />
            </div>
          </div>
          
    <!-- Infinite Scroll Sentinel -->
          <div
            :if={@has_more && !@loading}
            id="channels-sentinel"
            phx-hook="InfiniteScroll"
            data-page={@page}
            class="h-4"
          />

          <div
            :if={@loading}
            class="grid gap-3 sm:gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
          >
            <.skeleton_channel_card :for={_ <- 1..12} />
          </div>
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

  defp premium_access?(user) do
    Access.can_play_global_content?(user, Iptv.get_global_provider())
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

  defp apply_route_context(socket, %{"provider_id" => provider_id}) do
    user = socket.assigns.current_scope.user
    provider = Iptv.get_playable_provider(user.id, provider_id)

    if provider do
      {:ok, assign_provider_context(socket, provider, :provider)}
    else
      {:redirect,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  defp apply_route_context(socket, _params) do
    provider = Iptv.get_global_provider()

    if provider do
      {:ok, assign_provider_context(socket, provider, :browse)}
    else
      {:redirect,
       socket
       |> put_flash(:error, "Catálogo não disponível. Configure um provedor.")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  defp assign_provider_context(socket, provider, mode) do
    user = socket.assigns.current_scope.user
    categories = Iptv.list_categories(provider.id, "live")
    categories = filter_adult_categories(categories, user.show_adult_content)

    socket
    |> assign(page_title: provider_page_title(provider, mode))
    |> assign(current_path: provider_current_path(provider, mode))
    |> assign(provider: provider)
    |> assign(mode: mode)
    |> assign(categories: categories)
    |> assign(epg_syncing: maybe_prepare_provider_updates(socket, provider))
  end

  defp provider_page_title(_provider, :browse), do: "Ao Vivo"
  defp provider_page_title(provider, :provider), do: "#{provider.name} - Ao Vivo"

  defp provider_current_path(_provider, :browse), do: "/browse"
  defp provider_current_path(provider, :provider), do: "/providers/#{provider.id}"

  defp maybe_prepare_provider_updates(socket, provider) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")
      maybe_sync_epg(provider)
    else
      false
    end
  end

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
  # Uses Oban worker for persistent, reliable background processing
  # Returns true if sync was enqueued, false if not needed
  defp maybe_sync_epg(provider) do
    # Check if EPG needs sync (stale or never synced)
    if epg_needs_sync?(provider) do
      # Enqueue Oban job to sync EPG for all channels
      Iptv.async_sync_epg(provider)
      true
    else
      false
    end
  end

  defp epg_needs_sync?(%{epg_synced_at: nil}), do: true

  defp epg_needs_sync?(provider) do
    interval = provider.epg_sync_interval_hours || 6
    hours_since_sync = DateTime.diff(DateTime.utc_now(), provider.epg_synced_at, :hour)
    hours_since_sync >= interval
  end
end
