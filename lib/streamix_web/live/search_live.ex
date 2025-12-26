defmodule StreamixWeb.SearchLive do
  @moduledoc """
  LiveView for global search across all content types.

  Features:
  - Search across live channels, movies, and series
  - Real-time search with debouncing
  - Content type filtering
  - Recent searches history
  """
  use StreamixWeb, :live_view

  import StreamixWeb.AppComponents
  import StreamixWeb.ContentComponents

  alias Streamix.Iptv

  @doc false
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Buscar")
      |> assign(current_path: "/search")
      |> assign(query: "")
      |> assign(filter: "all")
      |> assign(results: %{channels: [], movies: [], series: []})
      |> assign(loading: false)
      |> assign(searched: false)

    {:ok, socket}
  end

  @doc false
  def handle_params(%{"q" => query}, _url, socket) when query != "" do
    socket =
      socket
      |> assign(query: query)
      |> assign(loading: true)
      |> perform_search()

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ============================================
  # Event Handlers
  # ============================================

  @doc false
  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply,
       assign(socket,
         query: "",
         results: %{channels: [], movies: [], series: []},
         searched: false
       )}
    else
      {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
    end
  end

  def handle_event("filter", %{"type" => type}, socket) do
    {:noreply, assign(socket, filter: type)}
  end

  def handle_event("play_channel", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/live_channel/#{id}")}
  end

  def handle_event("play_movie", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/movie/#{id}")}
  end

  def handle_event("view_series", %{"id" => id, "provider_id" => provider_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/providers/#{provider_id}/series/#{id}")}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => type}, socket) do
    user_id = socket.assigns.current_scope.user.id
    content_id = String.to_integer(id)

    # Check if already favorite and toggle
    if Iptv.is_favorite?(user_id, type, content_id) do
      Iptv.remove_favorite(user_id, type, content_id)
    else
      content = get_content(type, content_id)

      if content do
        Iptv.add_favorite(user_id, %{
          content_type: type,
          content_id: content_id,
          content_name: get_content_name(content, type),
          content_icon: get_content_icon(content, type)
        })
      end
    end

    # Refresh results to update favorite status
    {:noreply, perform_search(socket)}
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-4">
        <h1 class="text-2xl font-bold">Buscar</h1>

        <form phx-submit="search" phx-change="search" class="max-w-xl">
          <label class="input input-bordered flex items-center gap-2">
            <.icon name="hero-magnifying-glass" class="size-5 text-base-content/50" />
            <input
              type="search"
              name="query"
              value={@query}
              placeholder="Buscar canais, filmes, séries..."
              phx-debounce="300"
              class="grow bg-transparent border-none focus:outline-none text-lg"
              autofocus
            />
            <span :if={@loading} class="loading loading-spinner loading-sm"></span>
          </label>
        </form>
      </div>

      <div :if={@searched && has_results?(@results)} class="space-y-6">
        <div class="flex gap-2">
          <.filter_button type="all" label="Todos" current={@filter} count={total_count(@results)} />
          <.filter_button
            type="channels"
            label="Canais"
            current={@filter}
            count={length(@results.channels)}
          />
          <.filter_button
            type="movies"
            label="Filmes"
            current={@filter}
            count={length(@results.movies)}
          />
          <.filter_button
            type="series"
            label="Séries"
            current={@filter}
            count={length(@results.series)}
          />
        </div>

        <.channels_section
          :if={@filter in ["all", "channels"] && Enum.any?(@results.channels)}
          channels={@results.channels}
          show_all={@filter == "channels"}
        />

        <.movies_section
          :if={@filter in ["all", "movies"] && Enum.any?(@results.movies)}
          movies={@results.movies}
          show_all={@filter == "movies"}
        />

        <.series_section
          :if={@filter in ["all", "series"] && Enum.any?(@results.series)}
          series={@results.series}
          show_all={@filter == "series"}
        />
      </div>

      <.empty_state
        :if={@searched && !has_results?(@results)}
        icon="hero-magnifying-glass"
        title="Nenhum resultado encontrado"
        message={"Não encontramos resultados para \"#{@query}\". Tente uma busca diferente."}
      />

      <.search_hints :if={!@searched} />
    </div>
    """
  end

  defp filter_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-type={@type}
      class={[
        "btn btn-sm gap-2",
        @current == @type && "btn-primary",
        @current != @type && "btn-ghost"
      ]}
    >
      {@label}
      <span :if={@count > 0} class="badge badge-xs">{@count}</span>
    </button>
    """
  end

  defp channels_section(assigns) do
    limit = if assigns.show_all, do: 100, else: 6
    channels = Enum.take(assigns.channels, limit)
    assigns = assign(assigns, :limited_channels, channels)

    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Canais ao Vivo</h2>
        <span class="text-sm text-base-content/60">{length(@channels)} resultados</span>
      </div>

      <div class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
        <.live_channel_card
          :for={channel <- @limited_channels}
          channel={channel}
          is_favorite={channel.is_favorite}
          on_play="play_channel"
          on_favorite="toggle_favorite"
        />
      </div>
    </section>
    """
  end

  defp movies_section(assigns) do
    limit = if assigns.show_all, do: 100, else: 6
    movies = Enum.take(assigns.movies, limit)
    assigns = assign(assigns, :limited_movies, movies)

    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Filmes</h2>
        <span class="text-sm text-base-content/60">{length(@movies)} resultados</span>
      </div>

      <div class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
        <div :for={movie <- @limited_movies}>
          <.movie_card movie={movie} is_favorite={movie.is_favorite} on_play="play_movie" />
        </div>
      </div>
    </section>
    """
  end

  defp series_section(assigns) do
    limit = if assigns.show_all, do: 100, else: 6
    series_list = Enum.take(assigns.series, limit)
    assigns = assign(assigns, :limited_series, series_list)

    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Séries</h2>
        <span class="text-sm text-base-content/60">{length(@series)} resultados</span>
      </div>

      <div class="grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
        <div :for={series <- @limited_series}>
          <.series_card series={series} is_favorite={series.is_favorite} />
        </div>
      </div>
    </section>
    """
  end

  defp search_hints(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-center">
      <div class="rounded-full bg-base-200 p-4 mb-4">
        <.icon name="hero-magnifying-glass" class="size-12 text-base-content/30" />
      </div>
      <h3 class="text-lg font-medium mb-4">O que você quer assistir?</h3>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 max-w-2xl">
        <div class="flex items-center gap-3 p-4 rounded-lg bg-base-200">
          <.icon name="hero-tv" class="size-8 text-primary" />
          <div class="text-left">
            <p class="font-medium">Canais</p>
            <p class="text-sm text-base-content/60">TV ao vivo</p>
          </div>
        </div>
        <div class="flex items-center gap-3 p-4 rounded-lg bg-base-200">
          <.icon name="hero-film" class="size-8 text-primary" />
          <div class="text-left">
            <p class="font-medium">Filmes</p>
            <p class="text-sm text-base-content/60">Catálogo VOD</p>
          </div>
        </div>
        <div class="flex items-center gap-3 p-4 rounded-lg bg-base-200">
          <.icon name="hero-video-camera" class="size-8 text-primary" />
          <div class="text-left">
            <p class="font-medium">Séries</p>
            <p class="text-sm text-base-content/60">Temporadas e episódios</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp perform_search(socket) do
    query = socket.assigns.query
    user_id = socket.assigns.current_scope.user.id

    if String.trim(query) == "" do
      socket
      |> assign(results: %{channels: [], movies: [], series: []})
      |> assign(loading: false)
      |> assign(searched: false)
    else
      # Search across all content types
      channels = search_channels(user_id, query)
      movies = search_movies(user_id, query)
      series = search_series(user_id, query)

      socket
      |> assign(results: %{channels: channels, movies: movies, series: series})
      |> assign(loading: false)
      |> assign(searched: true)
    end
  end

  defp search_channels(user_id, query) do
    Iptv.search_channels(user_id, query, limit: 24)
    |> Enum.map(fn channel ->
      Map.put(channel, :is_favorite, Iptv.is_favorite?(user_id, "live_channel", channel.id))
    end)
  end

  defp search_movies(user_id, query) do
    Iptv.search_movies(user_id, query, limit: 24)
    |> Enum.map(fn movie ->
      Map.put(movie, :is_favorite, Iptv.is_favorite?(user_id, "movie", movie.id))
    end)
  end

  defp search_series(user_id, query) do
    Iptv.search_series(user_id, query, limit: 24)
    |> Enum.map(fn series ->
      Map.put(series, :is_favorite, Iptv.is_favorite?(user_id, "series", series.id))
    end)
  end

  defp get_content("live_channel", id), do: Iptv.get_channel(id)
  defp get_content("movie", id), do: Iptv.get_movie(id)
  defp get_content("series", id), do: Iptv.get_series(id)
  defp get_content(_, _), do: nil

  defp get_content_name(content, "live_channel"), do: content.name
  defp get_content_name(content, "movie"), do: content[:title] || content.name
  defp get_content_name(content, "series"), do: content[:title] || content.name
  defp get_content_name(_, _), do: nil

  defp get_content_icon(content, "live_channel"), do: content.stream_icon
  defp get_content_icon(content, "movie"), do: content.stream_icon || content[:cover]
  defp get_content_icon(content, "series"), do: content[:cover]
  defp get_content_icon(_, _), do: nil

  defp has_results?(results) do
    Enum.any?(results.channels) || Enum.any?(results.movies) || Enum.any?(results.series)
  end

  defp total_count(results) do
    length(results.channels) + length(results.movies) + length(results.series)
  end
end
