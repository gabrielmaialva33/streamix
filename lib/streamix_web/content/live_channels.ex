defmodule StreamixWeb.Content.LiveChannels do
  @moduledoc """
  Shared operations for the live-channel browse LiveView.
  """

  import Phoenix.Component, only: [assign: 2]

  import StreamixWeb.Helpers.Params, only: [parse_integer: 1]

  alias Phoenix.LiveView
  alias Streamix.Iptv
  alias Streamix.Iptv.Epg
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.FavoriteState

  use StreamixWeb, :verified_routes

  @per_page 50

  def init_socket(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(page_title: "Ao Vivo")
    |> assign(current_path: "/browse")
    |> assign(provider: nil)
    |> assign(mode: :browse)
    |> assign(premium_access: Detail.premium_access?(user))
    |> assign(categories: [])
    |> assign(selected_category: nil)
    |> assign(search: "")
    |> assign(page: 1)
    |> assign(has_more: true)
    |> assign(loading: false)
    |> assign(playing_channel: nil)
    |> assign(favorites_map: %{})
    |> assign(empty_results: false)
    |> assign(user_id: user.id)
    |> assign(epg_syncing: false)
    |> LiveView.stream(:channels, [])
    |> load_favorites_map()
  end

  def assign_params(socket, params) do
    category = parse_integer(params["category"])
    search = params["search"] || ""

    case apply_route_context(socket, params) do
      {:ok, socket} ->
        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(page: 1)
          |> LiveView.stream(:channels, [], reset: true)
          |> load_channels()

        {:ok, socket}

      {:redirect, socket} ->
        {:redirect, socket}
    end
  end

  def load_more(socket) do
    if socket.assigns.loading or not socket.assigns.has_more do
      socket
    else
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_channels()
    end
  end

  def play_channel(socket, id) do
    with channel_id when is_integer(channel_id) <- parse_integer(id),
         channel <- Iptv.get_live_channel_with_provider!(channel_id) do
      Iptv.add_watch_history(socket.assigns.user_id, "live_channel", channel.id, %{
        content_name: channel.name,
        content_icon: channel.stream_icon
      })

      assign(socket, playing_channel: channel)
    else
      _ -> socket
    end
  end

  def toggle_favorite(socket, id) do
    channel_id = parse_integer(id)

    if is_nil(channel_id) do
      socket
    else
      channel = Iptv.get_live_channel!(channel_id)

      case FavoriteState.toggle(socket.assigns.user_id, "live_channel", channel_id, %{
             content_name: channel.name,
             content_icon: channel.stream_icon
           }) do
        {:ok, status} ->
          socket
          |> FavoriteState.apply_map(:favorites_map, channel_id, status)
          |> LiveView.stream_insert(:channels, channel)

        {:error, _reason} ->
          socket
      end
    end
  end

  def refresh_epg(socket, nil, _channel_ids), do: socket
  def refresh_epg(socket, _provider, []), do: socket

  def refresh_epg(socket, provider, channel_ids) do
    ids =
      channel_ids
      |> Enum.map(&parse_integer/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.take(@per_page)

    refresh_epg_by_id(socket, provider, ids)
  end

  def update_provider_after_sync(socket, %{status: status} = payload) do
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

    assign(socket, provider: updated_provider)
  end

  def reload_after_sync(socket) do
    socket
    |> assign(page: 1)
    |> LiveView.stream(:channels, [], reset: true)
    |> load_channels()
  end

  def complete_provider_sync(socket) do
    provider = socket.assigns.provider
    categories = Iptv.list_categories(provider.id, "live")

    socket
    |> assign(categories: categories)
    |> reload_after_sync()
    |> Phoenix.LiveView.put_flash(:info, "Sincronização concluída!")
  end

  def start_provider_sync(socket) do
    provider = socket.assigns.provider
    Iptv.async_sync_provider(provider)

    socket
    |> assign(provider: %{provider | sync_status: "pending"})
    |> Phoenix.LiveView.put_flash(:info, "Sincronização iniciada")
  end

  def load_channels(socket) do
    user = socket.assigns.current_scope.user
    provider = socket.assigns.provider

    opts =
      [
        limit: @per_page,
        offset: (socket.assigns.page - 1) * @per_page,
        show_adult: user.show_adult_content
      ]
      |> maybe_add_filter(:category_id, socket.assigns.selected_category)
      |> maybe_add_filter(:search, socket.assigns.search)

    channels =
      provider.id
      |> Iptv.list_live_channels(opts)
      |> Iptv.enrich_channels_with_epg(provider.id)

    socket
    |> LiveView.stream(:channels, channels)
    |> assign(has_more: length(channels) == @per_page)
    |> assign(loading: false)
    |> assign(empty_results: socket.assigns.page == 1 and Enum.empty?(channels))
  end

  def build_path(%{assigns: %{mode: :browse}}, nil, ""), do: ~p"/browse"
  def build_path(%{assigns: %{mode: :browse}}, nil, search), do: ~p"/browse?search=#{search}"
  def build_path(%{assigns: %{mode: :browse}}, category, ""), do: ~p"/browse?category=#{category}"

  def build_path(%{assigns: %{mode: :browse}}, category, search),
    do: ~p"/browse?category=#{category}&search=#{search}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}?search=#{search}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}?category=#{category}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}?category=#{category}&search=#{search}"

  def empty_message(:provider, "idle"), do: "Sincronize o provedor para carregar os canais"
  def empty_message(_, _), do: "Tente ajustar seus filtros"

  def format_relative_time(nil), do: "Nunca"

  def format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "agora mesmo"
      diff < 3600 -> "#{div(diff, 60)}min atrás"
      diff < 86_400 -> "#{div(diff, 3600)}h atrás"
      true -> "#{div(diff, 86_400)}d atrás"
    end
  end

  defp apply_route_context(socket, %{"provider_id" => provider_id}) do
    user = socket.assigns.current_scope.user
    provider = Iptv.get_playable_provider(user.id, provider_id)

    if provider do
      {:ok, assign_provider_context(socket, provider, :provider)}
    else
      {:redirect,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         "Esse provedor não está disponível para sua conta. Pode estar inativo, ter sido removido ou ser privado de outro usuário."
       )
       |> Phoenix.LiveView.push_navigate(to: ~p"/providers")}
    end
  end

  defp apply_route_context(socket, _params) do
    case Iptv.get_global_provider() do
      nil ->
        {:redirect,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Catálogo não disponível. Configure um provedor.")
         |> Phoenix.LiveView.push_navigate(to: ~p"/providers")}

      provider ->
        {:ok, assign_provider_context(socket, provider, :browse)}
    end
  end

  defp assign_provider_context(socket, provider, mode) do
    user = socket.assigns.current_scope.user

    categories =
      provider.id
      |> Iptv.list_categories("live")
      |> filter_adult_categories(user.show_adult_content)

    socket
    |> assign(page_title: provider_page_title(provider, mode))
    |> assign(current_path: provider_current_path(provider, mode))
    |> assign(provider: provider)
    |> assign(mode: mode)
    |> assign(categories: categories)
    |> assign(epg_syncing: maybe_prepare_provider_updates(socket, provider))
  end

  defp refresh_epg_by_id(socket, _provider, []), do: socket

  defp refresh_epg_by_id(socket, provider, ids) do
    programs = Epg.current_programs_for_channels(provider.id, ids)

    Enum.reduce(ids, socket, fn channel_id, socket ->
      case Iptv.get_live_channel(channel_id) do
        nil ->
          socket

        channel ->
          current = Map.get(programs, to_string(channel_id))
          LiveView.stream_insert(socket, :channels, Map.put(channel, :current_program, current))
      end
    end)
  end

  defp load_favorites_map(socket) do
    favorite_ids = Iptv.list_favorite_ids(socket.assigns.user_id, "live_channel")
    assign(socket, favorites_map: favorite_ids)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  defp provider_page_title(_provider, :browse), do: "Ao Vivo"
  defp provider_page_title(provider, :provider), do: "#{provider.name} - Ao Vivo"

  defp provider_current_path(_provider, :browse), do: "/browse"
  defp provider_current_path(provider, :provider), do: "/providers/#{provider.id}"

  defp maybe_prepare_provider_updates(socket, provider) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")
      maybe_sync_epg(provider)
    else
      false
    end
  end

  defp maybe_sync_epg(provider) do
    if epg_needs_sync?(provider) do
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
