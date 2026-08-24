defmodule StreamixWeb.Content.Browse do
  @moduledoc """
  Shared browse workflow for movie and series LiveViews.

  The LiveViews keep their templates and event names; this module owns route
  context, pagination, list queries, favorites, and path generation.
  """

  import Phoenix.Component, only: [assign: 2]

  import StreamixWeb.Helpers.Params, only: [parse_integer: 1]

  alias Phoenix.LiveView
  alias Streamix.Library
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.FavoriteState

  use StreamixWeb, :verified_routes

  @per_page 48
  @max_restore_pages 25

  @configs %{
    movies: %{
      stream: :movies,
      content_type: "movie",
      category_type: "vod",
      title: "Filmes",
      browse_path: "/browse/movies",
      gindex_title: "Filmes - GDrive",
      valid_sorts: ~w(new trending rating)
    },
    series: %{
      stream: :series,
      content_type: "series",
      category_type: "series",
      title: "Séries",
      browse_path: "/browse/series",
      gindex_title: "Séries - GDrive",
      valid_sorts: ~w(popularity rating)
    }
  }

  def init_socket(socket, kind) do
    user = socket.assigns.current_scope.user
    config = config!(kind)

    socket
    |> assign(user_id: user.id)
    |> assign(user: user)
    |> assign(premium_access: Detail.premium_access?(user))
    |> assign(mode: :browse)
    |> assign(source: "iptv")
    |> assign(provider: nil)
    |> assign(provider_filter: "all")
    |> assign(provider_options: [])
    |> assign(categories: [])
    |> assign(selected_category: nil)
    |> assign(search: "")
    |> assign(page: 1)
    |> assign(has_more: true)
    |> assign(loading: false)
    |> assign(favorites_map: %{})
    |> assign(empty_results: false)
    |> assign(page_title: config.title)
    |> assign(current_path: config.browse_path)
    |> assign(gindex_count: 0)
    |> assign(sort: nil)
    |> LiveView.stream(config.stream, [])
  end

  def assign_params(socket, kind, params) do
    source = params["source"] || "iptv"
    category = parse_integer(params["category"])
    search = params["search"] || ""
    sort = parse_sort(kind, params["sort"])
    restore_page = restore_page(params["page"])

    case apply_route_context(socket, kind, params, source) do
      {:ok, socket} ->
        category = selected_category_for(socket.assigns, category)

        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(sort: sort)
          |> assign(page: 1)
          |> assign(has_more: true)
          |> assign(loading: false)
          |> assign(empty_results: false)
          |> LiveView.stream(config!(kind).stream, [], reset: true)
          |> load_through_page(kind, restore_page)
          |> load_favorites_map(kind)

        {:ok, socket}

      {:redirect, socket} ->
        {:redirect, socket}
    end
  end

  def load_more(socket, kind) do
    if socket.assigns.loading or not socket.assigns.has_more do
      socket
    else
      socket
      |> assign(page: socket.assigns.page + 1)
      |> assign(loading: true)
      |> load_items(kind)
    end
  end

  def toggle_favorite(socket, kind, id) do
    case parse_integer(id) do
      nil -> socket
      item_id -> toggle_playable_favorite(socket, kind, item_id)
    end
  end

  defp toggle_playable_favorite(socket, kind, item_id) do
    case get_playable_item(kind, socket.assigns.user_id, item_id) do
      nil -> socket
      item -> toggle_loaded_favorite(socket, kind, item_id, item)
    end
  end

  defp toggle_loaded_favorite(socket, kind, item_id, item) do
    config = config!(kind)

    case FavoriteState.toggle(
           socket.assigns.user_id,
           config.content_type,
           item_id,
           favorite_attrs(kind, item)
         ) do
      {:ok, status} ->
        socket
        |> FavoriteState.apply_map(:favorites_map, item_id, status)
        |> LiveView.stream_insert(config.stream, item)

      {:error, _reason} ->
        socket
    end
  end

  def counts(%{source: "gindex", gindex_counts: counts}, _kind) do
    %{live: 0, movies: counts.movies, series: counts.series, animes: counts.animes}
  end

  def counts(
        %{mode: :browse, source: "iptv", provider_filter: "all", provider_options: providers},
        _kind
      ) do
    %{
      live: sum_provider_count(providers, :live_channels_count),
      movies: sum_provider_count(providers, :movies_count),
      series: sum_provider_count(providers, :series_count)
    }
  end

  def counts(%{provider: nil}, _kind), do: %{live: 0, movies: 0, series: 0, animes: 0}

  def counts(%{provider: provider}, _kind) do
    %{
      live: provider.live_channels_count,
      movies: provider.movies_count,
      series: provider.series_count
    }
  end

  def build_path(%{assigns: assigns}, kind, category, search) do
    config = config!(kind)
    params = query_params(assigns.source, assigns.provider_filter, category, search)

    case assigns.mode do
      :browse ->
        append_query(config.browse_path, params)

      :provider ->
        append_query(provider_path(kind, assigns.provider), Map.delete(params, "source"))
    end
  end

  def provider_filter_path(%{assigns: assigns}, kind, provider_filter) do
    config = config!(kind)
    provider_filter = provider_filter(provider_filter)

    append_query(
      config.browse_path,
      query_params(assigns.source, provider_filter, nil, assigns.search)
    )
  end

  def browse_tab_params(%{source: "iptv"} = assigns) do
    %{}
    |> maybe_put_provider_query(assigns.provider_filter)
    |> maybe_put_query("search", assigns.search)
  end

  def browse_tab_params(%{source: "gindex"} = assigns) do
    %{}
    |> maybe_put_query("search", assigns.search)
  end

  def browse_tab_params(_assigns), do: %{}

  def detail_path(%{assigns: assigns}, kind, id) do
    assigns
    |> detail_destination(kind, id)
    |> with_return_to(browse_return_path(assigns, kind))
  end

  defp parse_sort(kind, sort) do
    if sort in config!(kind).valid_sorts, do: sort
  end

  defp restore_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 1 -> min(page, @max_restore_pages)
      _ -> 1
    end
  end

  defp restore_page(_page), do: 1

  defp apply_route_context(socket, kind, %{"provider_id" => provider_id}, _source) do
    config = config!(kind)
    provider = Streamix.Providers.get_playable_provider(socket.assigns.user_id, provider_id)

    if provider do
      user = socket.assigns.user

      categories =
        provider.id
        |> Streamix.Catalog.list_categories(config.category_type)
        |> filter_adult_categories(user.show_adult_content)

      {:ok,
       socket
       |> assign(page_title: "#{config.title} - #{provider.name}")
       |> assign(current_path: provider_path(kind, provider))
       |> assign(provider: provider)
       |> assign(provider_filter: Integer.to_string(provider.id))
       |> assign(provider_options: provider_options(socket.assigns.user_id))
       |> assign(mode: :provider)
       |> assign(source: "iptv")
       |> assign(categories: categories)
       |> assign(gindex_counts: Streamix.Catalog.gindex_counts())}
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

  # Torrent has its own dedicated screen (`/torrent`) — it is not a
  # source that shares the generic catalog grid. Redirect legacy
  # `?source=torrent` links there instead of silently falling back to
  # the IPTV provider.
  defp apply_route_context(socket, _kind, _params, "torrent") do
    {:redirect, LiveView.push_navigate(socket, to: "/torrent")}
  end

  defp apply_route_context(socket, kind, _params, "gindex") do
    config = config!(kind)

    {:ok,
     socket
     |> assign(page_title: config.gindex_title)
     |> assign(current_path: config.browse_path)
     |> assign(provider: nil)
     |> assign(provider_filter: "all")
     |> assign(provider_options: provider_options(socket.assigns.user_id))
     |> assign(mode: :browse)
     |> assign(source: "gindex")
     |> assign(categories: [])
     |> assign(gindex_counts: Streamix.Catalog.gindex_counts())}
  end

  defp apply_route_context(socket, kind, params, _source) do
    config = config!(kind)
    user = socket.assigns.user
    provider_filter = provider_filter(params["provider"])
    provider = selected_browse_provider(socket.assigns.user_id, provider_filter)

    categories =
      cond do
        provider_filter == "all" ->
          []

        is_nil(provider) ->
          []

        true ->
          provider.id
          |> Streamix.Catalog.list_categories(config.category_type)
          |> filter_adult_categories(user.show_adult_content)
      end

    {:ok,
     socket
     |> assign(page_title: provider_page_title(config.title, provider, provider_filter))
     |> assign(current_path: with_provider_query(config.browse_path, provider_filter))
     |> assign(provider: provider)
     |> assign(provider_filter: provider_filter)
     |> assign(provider_options: provider_options(socket.assigns.user_id))
     |> assign(mode: :browse)
     |> assign(source: "iptv")
     |> assign(categories: categories)
     |> assign(gindex_counts: Streamix.Catalog.gindex_counts())}
  end

  defp load_items(%{assigns: %{source: "gindex"}} = socket, :movies) do
    user = socket.assigns.user
    page = socket.assigns.page

    items =
      Streamix.Catalog.list_gindex_movies(
        search: socket.assigns.search,
        limit: @per_page,
        offset: offset(page),
        show_adult: user.show_adult_content
      )

    assign_items(socket, :movies, items)
  end

  defp load_items(%{assigns: %{source: "gindex"}} = socket, :series) do
    page = socket.assigns.page

    items =
      Streamix.Catalog.list_gindex_series(
        search: socket.assigns.search,
        limit: @per_page,
        offset: offset(page)
      )

    assign_items(socket, :series, items)
  end

  defp load_items(%{assigns: %{source: "iptv", provider_filter: "all"}} = socket, kind) do
    user = socket.assigns.user
    config = config!(kind)

    items =
      list_visible_items(kind, socket.assigns.user_id,
        search: socket.assigns.search,
        limit: @per_page,
        offset: offset(socket.assigns.page),
        dedupe: true,
        show_adult: user.show_adult_content
      )

    assign_items(socket, config.stream, items)
  end

  defp load_items(%{assigns: %{source: "iptv", provider: nil, sort: sort}} = socket, :movies)
       when sort in ["new", "trending", "rating"] do
    pagination = [
      limit: @per_page,
      offset: offset(socket.assigns.page),
      show_adult: socket.assigns.user.show_adult_content
    ]

    items =
      case sort do
        "new" -> Streamix.Catalog.list_new_releases(pagination)
        "trending" -> Streamix.Catalog.list_trending("movies", pagination)
        "rating" -> Streamix.Catalog.list_top_10_movies(pagination)
      end

    assign_items(socket, :movies, items, sort != "rating")
  end

  defp load_items(%{assigns: %{source: "iptv", provider: nil, sort: sort}} = socket, :series)
       when sort in ["popularity", "rating"] do
    pagination = [
      limit: @per_page,
      offset: offset(socket.assigns.page),
      show_adult: socket.assigns.user.show_adult_content
    ]

    items =
      case sort do
        "popularity" -> Streamix.Catalog.list_trending("series", pagination)
        "rating" -> Streamix.Catalog.list_top_10_series(pagination)
      end

    assign_items(socket, :series, items, sort != "rating")
  end

  defp load_items(%{assigns: %{provider: nil}} = socket, _kind) do
    socket
    |> assign(has_more: false)
    |> assign(loading: false)
    |> assign(empty_results: true)
  end

  defp load_items(socket, kind) do
    user = socket.assigns.user
    provider_id = socket.assigns.provider.id
    config = config!(kind)

    items =
      list_provider_items(kind, provider_id,
        category_id: socket.assigns.selected_category,
        search: socket.assigns.search,
        limit: @per_page,
        offset: offset(socket.assigns.page),
        dedupe: true,
        show_adult: user.show_adult_content
      )

    assign_items(socket, config.stream, items)
  end

  defp assign_items(socket, stream, items, can_have_more \\ true) do
    has_more = can_have_more and length(items) >= @per_page
    empty_results = socket.assigns.page == 1 and Enum.empty?(items)

    socket
    |> LiveView.stream(stream, items)
    |> assign(has_more: has_more)
    |> assign(loading: false)
    |> assign(empty_results: empty_results)
  end

  defp load_through_page(socket, kind, target_page) do
    Enum.reduce_while(1..target_page, socket, fn page, socket ->
      if page == 1 or socket.assigns.has_more do
        socket =
          socket
          |> assign(page: page)
          |> assign(loading: true)
          |> load_items(kind)

        {:cont, socket}
      else
        {:halt, socket}
      end
    end)
  end

  defp load_favorites_map(socket, kind) do
    favorite_ids = Library.list_favorite_ids(socket.assigns.user_id, config!(kind).content_type)
    assign(socket, favorites_map: favorite_ids)
  end

  defp list_provider_items(:movies, provider_id, opts),
    do: Streamix.Catalog.list_movies(provider_id, opts)

  defp list_provider_items(:series, provider_id, opts),
    do: Streamix.Catalog.list_series(provider_id, opts)

  defp list_visible_items(:movies, user_id, opts),
    do: Streamix.Catalog.list_visible_movies(user_id, opts)

  defp list_visible_items(:series, user_id, opts),
    do: Streamix.Catalog.list_visible_series(user_id, opts)

  defp get_playable_item(:movies, user_id, id),
    do: Streamix.Playback.get_playable_movie(user_id, id)

  defp get_playable_item(:series, user_id, id),
    do: Streamix.Playback.get_playable_series(user_id, id)

  defp favorite_attrs(:movies, movie) do
    %{
      content_type: "movie",
      content_id: movie.id,
      content_name: movie.title || movie.name,
      content_icon: movie.stream_icon
    }
  end

  defp favorite_attrs(:series, series) do
    %{
      content_type: "series",
      content_id: series.id,
      content_name: series.title || series.name,
      content_icon: series.cover
    }
  end

  defp query_params("gindex", _provider_filter, category, search) do
    %{"source" => "gindex"}
    |> maybe_put_query("category", category)
    |> maybe_put_query("search", search)
  end

  defp query_params(_source, provider_filter, category, search) do
    %{}
    |> maybe_put_provider_query(provider_filter)
    |> maybe_put_query("category", category)
    |> maybe_put_query("search", search)
  end

  defp browse_return_path(assigns, kind) do
    params =
      assigns.source
      |> query_params(assigns.provider_filter, assigns.selected_category, assigns.search)
      |> maybe_put_query("sort", assigns.sort)
      |> maybe_put_page(assigns.page)

    case assigns.mode do
      :browse ->
        append_query(config!(kind).browse_path, params)

      :provider ->
        append_query(provider_path(kind, assigns.provider), Map.delete(params, "source"))
    end
  end

  defp detail_destination(%{source: "gindex"}, :movies, id), do: ~p"/gindex/movies/#{id}"
  defp detail_destination(%{source: "gindex"}, :series, id), do: ~p"/gindex/series/#{id}"

  defp detail_destination(%{mode: :browse, provider_filter: provider_filter}, :movies, id),
    do: with_provider_query(~p"/browse/movies/#{id}", provider_filter)

  defp detail_destination(%{mode: :browse, provider_filter: provider_filter}, :series, id),
    do: with_provider_query(~p"/browse/series/#{id}", provider_filter)

  defp detail_destination(%{mode: :provider, provider: provider}, :movies, id),
    do: ~p"/providers/#{provider.id}/movies/#{id}"

  defp detail_destination(%{mode: :provider, provider: provider}, :series, id),
    do: ~p"/providers/#{provider.id}/series/#{id}"

  defp with_return_to(path, return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp maybe_put_provider_query(params, provider_filter) when provider_filter in [nil, "all"],
    do: params

  defp maybe_put_provider_query(params, provider_filter),
    do: Map.put(params, "provider", provider_filter)

  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: Map.put(params, key, value)

  defp maybe_put_page(params, page) when is_integer(page) and page > 1,
    do: Map.put(params, "page", page)

  defp maybe_put_page(params, _page), do: params

  defp append_query(path, params) when map_size(params) == 0, do: path

  defp append_query(path, params) do
    path <> "?" <> URI.encode_query(params)
  end

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  defp offset(page), do: (page - 1) * @per_page

  defp selected_category_for(%{source: "iptv", mode: :browse, provider_filter: "all"}, _category),
    do: nil

  defp selected_category_for(_assigns, category), do: category

  defp provider_path(:movies, provider), do: "/providers/#{provider.id}/movies"
  defp provider_path(:series, provider), do: "/providers/#{provider.id}/series"

  defp config!(kind), do: Map.fetch!(@configs, kind)

  defp provider_options(user_id) do
    user_id
    |> Streamix.Providers.list_visible_providers()
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

  defp selected_browse_provider(_user_id, "all"), do: Streamix.Providers.get_global_provider()

  defp selected_browse_provider(user_id, provider_filter) do
    case Integer.parse(provider_filter) do
      {provider_id, ""} -> Streamix.Providers.get_playable_provider(user_id, provider_id)
      _ -> Streamix.Providers.get_global_provider()
    end
  end

  defp provider_page_title(title, provider, provider_filter)
       when provider_filter not in [nil, "all"] and not is_nil(provider),
       do: "#{title} - #{provider.name}"

  defp provider_page_title(title, _provider, _provider_filter), do: title

  defp with_provider_query(path, provider_filter) when provider_filter in [nil, "all"], do: path

  defp with_provider_query(path, provider_filter) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "provider=" <> URI.encode_www_form(provider_filter)
  end
end
