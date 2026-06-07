defmodule StreamixWeb.Content.Browse do
  @moduledoc """
  Shared browse workflow for movie and series LiveViews.

  The LiveViews keep their templates and event names; this module owns route
  context, pagination, list queries, favorites, and path generation.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Phoenix.LiveView
  alias Streamix.Access
  alias Streamix.Iptv
  alias StreamixWeb.Content.FavoriteState

  use StreamixWeb, :verified_routes

  @per_page 48

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
    |> assign(premium_access: premium_access?(user))
    |> assign(mode: :browse)
    |> assign(source: "iptv")
    |> assign(provider: nil)
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

    case apply_route_context(socket, kind, params, source) do
      {:ok, socket} ->
        socket =
          socket
          |> assign(selected_category: category)
          |> assign(search: search)
          |> assign(sort: sort)
          |> assign(page: 1)
          |> LiveView.stream(config!(kind).stream, [], reset: true)
          |> load_items(kind)
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
    item_id = parse_integer(id)

    if is_nil(item_id) do
      socket
    else
      config = config!(kind)
      item = get_item!(kind, item_id)

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
  end

  def counts(%{source: "gindex", gindex_counts: counts}, _kind) do
    %{live: 0, movies: counts.movies, series: counts.series, animes: counts.animes}
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
    params = query_params(assigns.source, category, search)

    case assigns.mode do
      :browse ->
        append_query(config.browse_path, params)

      :provider ->
        append_query(provider_path(kind, assigns.provider), Map.delete(params, "source"))
    end
  end

  def detail_path(%{assigns: %{source: "gindex"}}, :movies, id), do: ~p"/gindex/movies/#{id}"
  def detail_path(%{assigns: %{source: "gindex"}}, :series, id), do: ~p"/gindex/series/#{id}"
  def detail_path(%{assigns: %{mode: :browse}}, :movies, id), do: ~p"/browse/movies/#{id}"
  def detail_path(%{assigns: %{mode: :browse}}, :series, id), do: ~p"/browse/series/#{id}"

  def detail_path(%{assigns: %{mode: :provider, provider: provider}}, :movies, id),
    do: ~p"/providers/#{provider.id}/movies/#{id}"

  def detail_path(%{assigns: %{mode: :provider, provider: provider}}, :series, id),
    do: ~p"/providers/#{provider.id}/series/#{id}"

  def parse_integer(nil), do: nil
  def parse_integer(""), do: nil

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def parse_integer(value), do: value

  defp parse_sort(kind, sort) do
    if sort in config!(kind).valid_sorts, do: sort
  end

  defp apply_route_context(socket, kind, %{"provider_id" => provider_id}, _source) do
    config = config!(kind)
    provider = Iptv.get_playable_provider(socket.assigns.user_id, provider_id)

    if provider do
      user = socket.assigns.user

      categories =
        provider.id
        |> Iptv.list_categories(config.category_type)
        |> filter_adult_categories(user.show_adult_content)

      {:ok,
       socket
       |> assign(page_title: "#{config.title} - #{provider.name}")
       |> assign(current_path: provider_path(kind, provider))
       |> assign(provider: provider)
       |> assign(mode: :provider)
       |> assign(source: "iptv")
       |> assign(categories: categories)
       |> assign(gindex_counts: Iptv.gindex_counts())}
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

  defp apply_route_context(socket, kind, _params, "gindex") do
    config = config!(kind)

    {:ok,
     socket
     |> assign(page_title: config.gindex_title)
     |> assign(current_path: config.browse_path)
     |> assign(provider: nil)
     |> assign(mode: :browse)
     |> assign(source: "gindex")
     |> assign(categories: [])
     |> assign(gindex_counts: Iptv.gindex_counts())}
  end

  defp apply_route_context(socket, kind, _params, _source) do
    config = config!(kind)
    user = socket.assigns.user
    provider = Iptv.get_global_provider()

    categories =
      case provider do
        nil -> []
        provider -> Iptv.list_categories(provider.id, config.category_type)
      end

    {:ok,
     socket
     |> assign(page_title: config.title)
     |> assign(current_path: config.browse_path)
     |> assign(provider: provider)
     |> assign(mode: :browse)
     |> assign(source: "iptv")
     |> assign(categories: filter_adult_categories(categories, user.show_adult_content))
     |> assign(gindex_counts: Iptv.gindex_counts())}
  end

  defp load_items(%{assigns: %{source: "gindex"}} = socket, :movies) do
    user = socket.assigns.user
    page = socket.assigns.page

    items =
      Iptv.list_gindex_movies(
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
      Iptv.list_gindex_series(
        search: socket.assigns.search,
        limit: @per_page,
        offset: offset(page)
      )

    assign_items(socket, :series, items)
  end

  defp load_items(%{assigns: %{source: "iptv", provider: nil, sort: sort}} = socket, :movies)
       when sort in ["new", "trending", "rating"] do
    items =
      case sort do
        "new" -> Iptv.list_new_releases(limit: socket.assigns.page * @per_page)
        "trending" -> Iptv.list_trending("movies", limit: socket.assigns.page * @per_page)
        "rating" -> Iptv.list_top_10_movies(limit: socket.assigns.page * @per_page)
      end
      |> Enum.drop(offset(socket.assigns.page))

    assign_items(socket, :movies, items, sort != "rating")
  end

  defp load_items(%{assigns: %{source: "iptv", provider: nil, sort: sort}} = socket, :series)
       when sort in ["popularity", "rating"] do
    items =
      case sort do
        "popularity" -> Iptv.list_trending("series", limit: socket.assigns.page * @per_page)
        "rating" -> Iptv.list_top_10_series(limit: socket.assigns.page * @per_page)
      end
      |> Enum.drop(offset(socket.assigns.page))

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

  defp load_favorites_map(socket, kind) do
    favorite_ids = Iptv.list_favorite_ids(socket.assigns.user_id, config!(kind).content_type)
    assign(socket, favorites_map: favorite_ids)
  end

  defp list_provider_items(:movies, provider_id, opts), do: Iptv.list_movies(provider_id, opts)
  defp list_provider_items(:series, provider_id, opts), do: Iptv.list_series(provider_id, opts)

  defp get_item!(:movies, id), do: Iptv.get_movie!(id)
  defp get_item!(:series, id), do: Iptv.get_series!(id)

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

  defp query_params("gindex", category, search) do
    %{"source" => "gindex"}
    |> maybe_put_query("category", category)
    |> maybe_put_query("search", search)
  end

  defp query_params(_source, category, search) do
    %{}
    |> maybe_put_query("category", category)
    |> maybe_put_query("search", search)
  end

  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: Map.put(params, key, value)

  defp append_query(path, params) when map_size(params) == 0, do: path

  defp append_query(path, params) do
    path <> "?" <> URI.encode_query(params)
  end

  defp premium_access?(user) do
    Access.plays_global_content?(user, Iptv.get_global_provider())
  end

  defp filter_adult_categories(categories, true), do: categories
  defp filter_adult_categories(categories, _), do: Enum.reject(categories, & &1.is_adult)

  defp offset(page), do: (page - 1) * @per_page

  defp provider_path(:movies, provider), do: "/providers/#{provider.id}/movies"
  defp provider_path(:series, provider), do: "/providers/#{provider.id}/series"

  defp config!(kind), do: Map.fetch!(@configs, kind)
end
