defmodule StreamixWeb.TorrentLive do
  @moduledoc """
  Dedicated screen for the torrent aggregator catalog.

  Distinct from the generic `/browse` grid because torrent content has
  its own signals — swarm health (seeders) and per-release quality — and
  is movies-only. Cards badge both so users pick a healthy release at a
  glance. Playback is gated downstream by the premium check and the
  rqbit buffering swarm.
  """
  use StreamixWeb, :live_view

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Filters
  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Iptv
  alias Streamix.Torrent
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.Helpers.ImageProxy

  @per_page 48

  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Torrent.provider()

    socket =
      socket
      |> assign(user_id: user_id)
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(has_more: provider != nil)
      |> assign(loading: false)
      |> assign(favorites_map: MapSet.new())
      |> assign(empty_results: false)
      |> assign(provider: provider)
      |> assign(total_count: Torrent.count_movies())
      |> assign(page_title: "Torrents")
      |> assign(current_path: "/torrent")
      |> stream(:movies, [])

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    search = params["search"] || ""

    socket =
      socket
      |> assign(search: search)
      |> assign(page: 1)
      |> assign(favorites_map: MapSet.new())
      |> stream(:movies, [], reset: true)
      |> load_movies()

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => search}, socket) do
    path = if search == "", do: ~p"/torrent", else: ~p"/torrent?search=#{search}"
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("load_more", _, socket) do
    if socket.assigns.loading or not socket.assigns.has_more do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(page: socket.assigns.page + 1)
        |> assign(loading: true)
        |> load_movies()

      {:noreply, socket}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case parse_positive_integer(id) do
      {:ok, movie_id} ->
        movie = Iptv.get_movie!(movie_id)

        case FavoriteState.toggle(user_id, "movie", movie_id, %{
               content_name: movie.title || movie.name,
               content_icon: movie.stream_icon
             }) do
          {:ok, status} ->
            {:noreply, FavoriteState.apply_map(socket, :favorites_map, movie_id, status)}

          {:error, _reason} ->
            {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <header class="space-y-1">
        <div class="flex items-center gap-2">
          <span class="inline-flex size-9 items-center justify-center rounded-lg bg-brand/15 text-brand">
            <.icon name="hero-bolt" class="size-5" />
          </span>
          <h1 class="text-2xl sm:text-3xl font-bold text-text-primary">Torrents</h1>
        </div>
        <p class="text-2sm text-text-secondary">
          Filmes via swarm P2P, ordenados por saúde da rede.
          <span :if={@total_count > 0} class="text-text-muted">
            {@total_count} títulos
          </span>
        </p>
      </header>

      <.search_input id="torrent-search-form" value={@search} placeholder="Buscar torrents..." />

      <div :if={!@provider} class="surface-card p-8 text-center">
        <.icon name="hero-bolt-slash" class="mx-auto size-10 text-text-muted" />
        <p class="mt-3 text-text-secondary">
          O agregador de torrents não está ativo nesta instância.
        </p>
      </div>

      <div id="torrents" phx-update="stream" class="responsive-poster-grid">
        <div :for={{dom_id, movie} <- @streams.movies} id={dom_id}>
          <.torrent_card
            movie={movie}
            is_favorite={MapSet.member?(@favorites_map, movie.id)}
            provider_id={@provider && @provider.id}
          />
        </div>
      </div>

      <div
        :if={@has_more && !@loading && @provider}
        id="torrents-sentinel"
        phx-hook="InfiniteScroll"
        data-page={@page}
        class="h-4"
      />

      <div :if={@loading} class="flex justify-center py-8">
        <.icon name="hero-arrow-path" class="size-8 text-brand animate-spin" />
      </div>

      <.empty_state
        :if={@empty_results && !@loading && @provider}
        icon="hero-bolt"
        title="Nenhum torrent encontrado"
        message="Tente outra busca ou volte mais tarde — o catálogo sincroniza periodicamente."
      />
    </div>
    """
  end

  # Dedicated torrent card: poster + quality/seeder badges.
  attr :movie, :map, required: true
  attr :is_favorite, :boolean, default: false
  attr :provider_id, :any, default: nil

  defp torrent_card(assigns) do
    ~H"""
    <div class="group relative">
      <.link navigate={detail_path(@provider_id, @movie.id)} class="block poster-card card-glow">
        <img
          :if={@movie.stream_icon}
          src={ImageProxy.card(@movie.stream_icon)}
          alt={@movie.title || @movie.name}
          class="h-full w-full object-cover"
          loading="lazy"
          decoding="async"
        />
        <div
          :if={!@movie.stream_icon}
          class="flex h-full w-full items-center justify-center bg-surface-hover text-text-muted"
        >
          <.icon name="hero-film" class="size-10" />
        </div>

        <span
          :if={@movie.torrent_quality}
          class="absolute top-2 left-2 rounded bg-black/70 px-1.5 py-0.5 text-2xs font-semibold text-white backdrop-blur-sm"
        >
          {@movie.torrent_quality}
        </span>

        <span class={[
          "absolute top-2 right-2 flex items-center gap-0.5 rounded px-1.5 py-0.5 text-2xs font-semibold backdrop-blur-sm",
          seeder_class(@movie.torrent_seeders)
        ]}>
          <.icon name="hero-arrow-up" class="size-3" />
          {@movie.torrent_seeders || 0}
        </span>
      </.link>

      <button
        type="button"
        phx-click="toggle_favorite"
        phx-value-id={@movie.id}
        class="absolute bottom-2 right-2 flex size-8 items-center justify-center rounded-full bg-black/60 text-white opacity-0 backdrop-blur-sm transition-opacity group-hover:opacity-100 focus:opacity-100"
        aria-label="Favoritar"
      >
        <.icon
          name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
          class={["size-4", @is_favorite && "text-brand"]}
        />
      </button>

      <div class="mt-2 space-y-0.5">
        <h3 class="truncate text-2sm font-medium text-text-primary group-hover:text-brand">
          {@movie.title || @movie.name}
        </h3>
        <p :if={@movie.year} class="text-2xs text-text-muted">{@movie.year}</p>
      </div>
    </div>
    """
  end

  # Healthy swarms read green, weak ones amber, dead ones muted.
  defp seeder_class(s) when is_integer(s) and s >= 20, do: "bg-success/85 text-black"
  defp seeder_class(s) when is_integer(s) and s > 0, do: "bg-warning/85 text-black"
  defp seeder_class(_), do: "bg-black/70 text-text-muted"

  # Torrent movies live behind the system torrent provider; the detail
  # page resolves it via the provider route.
  defp detail_path(nil, movie_id),
    do: with_return_to(~p"/browse/movies/#{movie_id}", ~p"/torrent")

  defp detail_path(provider_id, movie_id),
    do: with_return_to(~p"/providers/#{provider_id}/movies/#{movie_id}", ~p"/torrent")

  defp with_return_to(path, return_to) do
    path <> "?return_to=" <> URI.encode_www_form(return_to)
  end

  defp load_movies(socket) do
    if socket.assigns.provider do
      movies =
        Torrent.list_movies(
          search: socket.assigns.search,
          limit: @per_page,
          offset: (socket.assigns.page - 1) * @per_page
        )

      has_more = length(movies) >= @per_page
      empty_results = socket.assigns.page == 1 and Enum.empty?(movies)

      favorite_ids =
        Iptv.list_favorite_ids(socket.assigns.user_id, "movie", Enum.map(movies, & &1.id))

      socket
      |> stream(:movies, movies)
      |> assign(favorites_map: MapSet.union(socket.assigns.favorites_map, favorite_ids))
      |> assign(has_more: has_more)
      |> assign(loading: false)
      |> assign(empty_results: empty_results)
    else
      socket
      |> assign(has_more: false)
      |> assign(loading: false)
      |> assign(empty_results: false)
    end
  end
end
