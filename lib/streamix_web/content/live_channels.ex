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
    |> assign(provider_filter: "all")
    |> assign(provider_options: [])
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
    provider_filter = provider_filter(params["provider"])

    case apply_route_context(socket, params, provider_filter) do
      {:ok, socket} ->
        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(provider_filter: provider_filter)
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

    opts =
      [
        limit: @per_page,
        offset: (socket.assigns.page - 1) * @per_page,
        show_adult: user.show_adult_content
      ]
      |> maybe_add_filter(:category_id, socket.assigns.selected_category)
      |> maybe_add_filter(:search, socket.assigns.search)

    channels =
      if socket.assigns.mode == :browse and socket.assigns.provider_filter == "all" do
        socket.assigns.user_id
        |> Iptv.list_visible_live_channels(Keyword.delete(opts, :category_id))
        |> enrich_channels_by_provider()
      else
        provider = socket.assigns.provider

        provider.id
        |> Iptv.list_live_channels(opts)
        |> Iptv.enrich_channels_with_epg(provider.id)
      end

    socket
    |> LiveView.stream(:channels, channels)
    |> assign(has_more: length(channels) == @per_page)
    |> assign(loading: false)
    |> assign(empty_results: socket.assigns.page == 1 and Enum.empty?(channels))
  end

  def build_path(%{assigns: %{mode: :browse} = assigns}, category, search) do
    %{}
    |> maybe_put_provider_query(assigns.provider_filter)
    |> maybe_put_query("category", category)
    |> maybe_put_query("search", search)
    |> then(&append_query(~p"/browse", &1))
  end

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, ""),
    do: ~p"/providers/#{provider.id}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, nil, search),
    do: ~p"/providers/#{provider.id}?search=#{search}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, category, ""),
    do: ~p"/providers/#{provider.id}?category=#{category}"

  def build_path(%{assigns: %{mode: :provider, provider: provider}}, category, search),
    do: ~p"/providers/#{provider.id}?category=#{category}&search=#{search}"

  def provider_filter_path(%{assigns: assigns}, provider_filter) do
    provider_filter = provider_filter(provider_filter)

    %{}
    |> maybe_put_provider_query(provider_filter)
    |> maybe_put_query("search", assigns.search)
    |> then(&append_query(~p"/browse", &1))
  end

  def empty_message(:provider, "idle"), do: "Sincronize o provedor para carregar os canais"
  def empty_message(_, _), do: "Tente ajustar seus filtros"

  def counts(%{provider_filter: "all", provider_options: providers}) do
    %{
      live: sum_provider_count(providers, :live_channels_count),
      movies: sum_provider_count(providers, :movies_count),
      series: sum_provider_count(providers, :series_count)
    }
  end

  def counts(%{provider: provider}) do
    %{
      live: provider.live_channels_count,
      movies: provider.movies_count,
      series: provider.series_count
    }
  end

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

  defp apply_route_context(socket, %{"provider_id" => provider_id}, _provider_filter) do
    user = socket.assigns.current_scope.user
    provider = Iptv.get_playable_provider(user.id, provider_id)

    if provider do
      {:ok, assign_provider_context(socket, provider, :provider, Integer.to_string(provider.id))}
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

  defp apply_route_context(socket, _params, provider_filter) do
    user = socket.assigns.current_scope.user

    case selected_browse_provider(user.id, provider_filter) do
      nil ->
        {:redirect,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Catálogo não disponível. Configure um provedor.")
         |> Phoenix.LiveView.push_navigate(to: ~p"/providers")}

      provider ->
        {:ok, assign_provider_context(socket, provider, :browse, provider_filter)}
    end
  end

  defp assign_provider_context(socket, provider, mode, provider_filter) do
    user = socket.assigns.current_scope.user

    categories =
      if mode == :browse and provider_filter == "all" do
        []
      else
        provider.id
        |> Iptv.list_categories("live")
        |> filter_adult_categories(user.show_adult_content)
      end

    socket
    |> assign(page_title: provider_page_title(provider, mode))
    |> assign(current_path: provider_current_path(provider, mode, provider_filter))
    |> assign(provider: provider)
    |> assign(provider_filter: provider_filter)
    |> assign(provider_options: provider_options(socket.assigns.user_id))
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

  defp enrich_channels_by_provider(channels) do
    channels
    |> Enum.group_by(& &1.provider_id)
    |> Enum.flat_map(fn {provider_id, provider_channels} ->
      Iptv.enrich_channels_with_epg(provider_channels, provider_id)
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: Map.put(params, key, value)

  defp maybe_put_provider_query(params, provider_filter) when provider_filter in [nil, "all"],
    do: params

  defp maybe_put_provider_query(params, provider_filter),
    do: Map.put(params, "provider", provider_filter)

  defp append_query(path, params) when map_size(params) == 0, do: path
  defp append_query(path, params), do: path <> "?" <> URI.encode_query(params)

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  defp provider_page_title(_provider, :browse), do: "Ao Vivo"
  defp provider_page_title(provider, :provider), do: "#{provider.name} - Ao Vivo"

  defp provider_current_path(_provider, :browse, provider_filter),
    do: append_query("/browse", maybe_put_provider_query(%{}, provider_filter))

  defp provider_current_path(provider, :provider, _provider_filter),
    do: "/providers/#{provider.id}"

  defp provider_options(user_id) do
    user_id
    |> Iptv.list_visible_providers()
    |> Enum.filter(&(&1.provider_type == :xtream))
  end

  defp sum_provider_count(providers, field) do
    Enum.reduce(providers, 0, fn provider, total -> total + Map.get(provider, field, 0) end)
  end

  defp provider_filter(nil), do: "all"
  defp provider_filter(""), do: "all"
  defp provider_filter("all"), do: "all"

  defp provider_filter(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> Integer.to_string(id)
      _ -> "all"
    end
  end

  defp provider_filter(_), do: "all"

  defp selected_browse_provider(_user_id, "all"), do: Iptv.get_global_provider()

  defp selected_browse_provider(user_id, provider_filter) do
    case Integer.parse(provider_filter) do
      {provider_id, ""} -> Iptv.get_playable_provider(user_id, provider_id)
      _ -> Iptv.get_global_provider()
    end
  end

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
