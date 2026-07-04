defmodule StreamixWeb.Content.LiveChannelsLive do
  @moduledoc """
  LiveView for browsing live channels from a provider.
  Works for both /browse (global provider) and /providers/:id (user provider).
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias StreamixWeb.Content.LiveChannels

  def mount(_params, _session, socket) do
    {:ok, LiveChannels.init_socket(socket)}
  end

  def handle_params(params, _url, socket) do
    case LiveChannels.assign_params(socket, params) do
      {:ok, socket} ->
        {:noreply, socket}

      {:redirect, socket} ->
        {:noreply, socket}
    end
  end

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category

    {:noreply,
     push_patch(socket, to: LiveChannels.build_path(socket, category, socket.assigns.search))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: LiveChannels.build_path(socket, socket.assigns.selected_category, search)
     )}
  end

  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    {:noreply, push_patch(socket, to: LiveChannels.provider_filter_path(socket, provider))}
  end

  def handle_event("load_more", _, socket) do
    {:noreply, LiveChannels.load_more(socket)}
  end

  def handle_event("play_channel", %{"id" => id}, socket) do
    {:noreply, LiveChannels.play_channel(socket, id)}
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
    {:noreply, LiveChannels.toggle_favorite(socket, id)}
  end

  # Periodic refresh of "now playing" EPG for visible cards (EpgRefresh hook).
  # We re-stream only channels whose current program changed so the diff stays
  # tiny — server-side cache already coalesces concurrent requests.
  def handle_event("refresh_epg", %{"channel_ids" => channel_ids}, socket)
      when is_list(channel_ids) do
    provider = socket.assigns.provider
    socket = LiveChannels.refresh_epg(socket, provider, channel_ids)

    {:noreply, socket}
  end

  def handle_event("refresh_epg", _, socket), do: {:noreply, socket}

  def handle_event("sync_provider", _, socket) do
    {:noreply, LiveChannels.start_provider_sync(socket)}
  end

  def handle_info({:sync_status, %{status: status} = payload}, socket) do
    socket = LiveChannels.update_provider_after_sync(socket, payload)

    if status == "completed" do
      {:noreply, LiveChannels.complete_provider_sync(socket)}
    else
      {:noreply, socket}
    end
  end

  # Handler for EPG sync completion (from Oban worker via PubSub)
  def handle_info({:epg_sync_complete, :ok, _results}, socket) do
    # Reload channels to pick up EPG data
    socket =
      socket
      |> assign(epg_syncing: false)
      |> LiveChannels.reload_after_sync()

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

        <.provider_filter
          :if={@mode == :browse}
          providers={@provider_options}
          selected={@provider_filter}
        />

        <.premium_cta_banner
          :if={@mode == :browse and not @premium_access}
          id="browse-premium-cta"
          current_scope={@current_scope}
        />
      </div>

      <div class="flex flex-col sm:flex-row gap-4 sm:gap-6">
        <.category_filter_v2
          :if={length(@categories) > 0}
          categories={@categories}
          selected={@selected_category}
          layout={:sidebar}
        />
        <div class="flex-1 min-w-0">
          <div
            id="channels"
            phx-update="stream"
            phx-hook="EpgRefresh"
            class="responsive-wide-grid"
          >
            <div
              :for={{dom_id, channel} <- @streams.channels}
              id={dom_id}
              data-epg-channel-id={channel.id}
            >
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
            class="responsive-wide-grid"
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

  defdelegate empty_message(mode, sync_status), to: LiveChannels
  defdelegate format_relative_time(datetime), to: LiveChannels
end
