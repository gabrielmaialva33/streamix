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

  import StreamixWeb.App.Feedback
  import StreamixWeb.App.Media
  import StreamixWeb.Content.CardComponents
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Iptv
  alias StreamixWeb.Content.FavoriteState

  @page_size 24
  @result_types %{"channels" => :channels, "movies" => :movies, "series" => :series}

  @doc false
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    socket =
      socket
      |> assign(page_title: "Buscar")
      |> assign(current_path: "/search")
      |> assign(query: "")
      |> assign(filter: "all")
      |> assign(result_counts: %{channels: 0, movies: 0, series: 0})
      |> assign(has_more: %{channels: false, movies: false, series: false})
      |> assign(loading: false)
      |> assign(searched: false)
      |> assign(user_id: user_id)
      |> stream(:search_channels, [])
      |> stream(:search_movies, [])
      |> stream(:search_series, [])

    {:ok, socket}
  end

  @doc false
  def handle_params(%{"q" => query}, _url, socket) when query != "" do
    socket =
      socket
      |> assign(query: query)
      |> assign(current_path: ~p"/search?q=#{query}")
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
      socket =
        socket
        |> assign(
          query: "",
          result_counts: %{channels: 0, movies: 0, series: 0},
          has_more: %{channels: false, movies: false, series: false},
          searched: false
        )
        |> reset_result_streams()

      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}
    end
  end

  def handle_event("filter", %{"type" => type}, socket) do
    {:noreply, assign(socket, filter: type)}
  end

  def handle_event("load_more", %{"type" => type}, socket) do
    case Map.fetch(@result_types, type) do
      {:ok, result_type} -> {:noreply, load_more_results(socket, result_type)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("play_channel", %{"id" => id}, socket) do
    {:noreply, redirect(socket, to: ~p"/watch/live_channel/#{id}")}
  end

  def handle_event("play_movie", %{"id" => id, "provider_id" => provider_id}, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         with_return_to(
           ~p"/providers/#{provider_id}/movies/#{id}",
           socket.assigns.current_path
         )
     )}
  end

  def handle_event("show_details", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: with_return_to(~p"/browse/movies/#{id}", socket.assigns.current_path)
     )}
  end

  def handle_event("view_series", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: with_return_to(~p"/browse/series/#{id}", socket.assigns.current_path)
     )}
  end

  def handle_event("toggle_favorite", %{"id" => id, "type" => type}, socket) do
    user_id = socket.assigns.user_id

    case parse_positive_integer(id) do
      {:ok, content_id} ->
        result = toggle_favorite(user_id, type, content_id)
        {:noreply, refresh_after_favorite(socket, result)}

      :error ->
        {:noreply, socket}
    end
  end

  defp toggle_favorite(user_id, type, content_id) do
    FavoriteState.toggle(user_id, type, content_id)
  end

  defp with_return_to(path, return_to) do
    path <> "?return_to=" <> URI.encode_www_form(return_to)
  end

  # ============================================
  # Render
  # ============================================

  @doc false
  def render(assigns) do
    ~H"""
    <div class="py-6 sm:py-8 space-y-6 sm:space-y-8">
      <div class="flex flex-col gap-4">
        <h1 class="text-3xl font-bold text-text-primary">Buscar</h1>

        <form id="global-search-form" phx-submit="search" phx-change="search" class="max-w-xl">
          <div class="flex items-center gap-3 px-4 py-3 bg-surface border border-border rounded-lg focus-within:border-brand focus-within:ring-2 focus-within:ring-brand/20 transition-colors">
            <.icon name="hero-magnifying-glass" class="size-5 text-text-secondary flex-shrink-0" />
            <%!--
              iOS Safari: disable auto-capitalize/correct/spellcheck so the
              search box doesn't fight the user typing titles. enterkeyhint
              swaps Return for Search on the iOS keyboard.
            --%>
            <input
              type="search"
              name="query"
              value={@query}
              placeholder="Buscar canais, filmes, séries..."
              phx-debounce="300"
              autocomplete="off"
              autocapitalize="off"
              autocorrect="off"
              spellcheck="false"
              enterkeyhint="search"
              class="flex-1 bg-transparent border-0 outline-none ring-0 focus:ring-0 focus:outline-none text-base sm:text-lg text-text-primary placeholder:text-text-muted"
              autofocus
            />
            <div
              :if={@loading}
              class="size-5 border-2 border-brand/30 border-t-brand rounded-full animate-spin flex-shrink-0"
              role="status"
              aria-label="Buscando"
            >
            </div>
          </div>
        </form>
      </div>

      <div :if={@searched && has_results?(@result_counts)} class="space-y-8">
        <div id="search-filter-strip" data-filter-strip class="filter-strip">
          <.filter_button
            type="all"
            label="Todos"
            current={@filter}
            count={total_count(@result_counts)}
            has_more={Enum.any?(Map.values(@has_more))}
          />
          <.filter_button
            type="channels"
            label="Canais"
            current={@filter}
            count={@result_counts.channels}
            has_more={@has_more.channels}
          />
          <.filter_button
            type="movies"
            label="Filmes"
            current={@filter}
            count={@result_counts.movies}
            has_more={@has_more.movies}
          />
          <.filter_button
            type="series"
            label="Séries"
            current={@filter}
            count={@result_counts.series}
            has_more={@has_more.series}
          />
        </div>

        <.channels_section
          :if={@result_counts.channels > 0}
          channels={@streams.search_channels}
          count={@result_counts.channels}
          has_more={@has_more.channels}
          hidden={@filter not in ["all", "channels"]}
        />

        <.movies_section
          :if={@result_counts.movies > 0}
          movies={@streams.search_movies}
          count={@result_counts.movies}
          has_more={@has_more.movies}
          hidden={@filter not in ["all", "movies"]}
        />

        <.series_section
          :if={@result_counts.series > 0}
          series={@streams.search_series}
          count={@result_counts.series}
          has_more={@has_more.series}
          hidden={@filter not in ["all", "series"]}
        />
      </div>

      <div
        :if={@searched && !has_results?(@result_counts)}
        id="search-empty"
        role="status"
        aria-live="polite"
      >
        <.empty_state
          icon="hero-magnifying-glass"
          title="Nenhum resultado encontrado"
          message={"Não encontramos resultados para \"#{@query}\". Tente uma busca diferente."}
        />
      </div>

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
        "min-h-11 flex-shrink-0 whitespace-nowrap rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-brand",
        @current == @type && "bg-brand text-white",
        @current != @type &&
          "bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary border border-border"
      ]}
    >
      {@label}
      <span :if={@count > 0} class="ml-2 px-1.5 py-0.5 text-xs rounded bg-black/20">
        {@count}{if @has_more, do: "+", else: ""}
      </span>
    </button>
    """
  end

  defp channels_section(assigns) do
    ~H"""
    <section id="search-channels-section" class={["space-y-4", @hidden && "hidden"]}>
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold text-text-primary">Canais ao Vivo</h2>
        <span class="text-sm text-text-secondary">
          {result_count_label(@count, @has_more)}
        </span>
      </div>

      <div id="search-channels-grid" phx-update="stream" class="responsive-wide-grid">
        <div :for={{dom_id, channel} <- @channels} id={dom_id}>
          <.live_channel_card
            channel={channel}
            is_favorite={channel.is_favorite}
            on_favorite="toggle_favorite"
          />
        </div>
      </div>

      <.load_more_button :if={@has_more} type="channels" label="Mostrar mais canais" />
    </section>
    """
  end

  defp movies_section(assigns) do
    ~H"""
    <section id="search-movies-section" class={["space-y-4", @hidden && "hidden"]}>
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold text-text-primary">Filmes</h2>
        <span class="text-sm text-text-secondary">
          {result_count_label(@count, @has_more)}
        </span>
      </div>

      <div id="search-movies-grid" phx-update="stream" class="responsive-poster-grid">
        <div :for={{dom_id, movie} <- @movies} id={dom_id}>
          <.movie_card movie={movie} is_favorite={movie.is_favorite} on_play="play_movie" />
        </div>
      </div>

      <.load_more_button :if={@has_more} type="movies" label="Mostrar mais filmes" />
    </section>
    """
  end

  defp series_section(assigns) do
    ~H"""
    <section id="search-series-section" class={["space-y-4", @hidden && "hidden"]}>
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold text-text-primary">Séries</h2>
        <span class="text-sm text-text-secondary">
          {result_count_label(@count, @has_more)}
        </span>
      </div>

      <div id="search-series-grid" phx-update="stream" class="responsive-poster-grid">
        <div :for={{dom_id, series} <- @series} id={dom_id}>
          <.series_card series={series} is_favorite={series.is_favorite} />
        </div>
      </div>

      <.load_more_button :if={@has_more} type="series" label="Mostrar mais séries" />
    </section>
    """
  end

  defp load_more_button(assigns) do
    ~H"""
    <div class="flex justify-center pt-2">
      <button
        id={"search-load-more-#{@type}"}
        type="button"
        phx-click="load_more"
        phx-value-type={@type}
        phx-disable-with="Carregando..."
        class="inline-flex min-h-11 items-center justify-center rounded-lg border border-border bg-surface px-5 py-2 text-sm font-medium text-text-primary transition-colors hover:bg-surface-hover focus:outline-none focus:ring-2 focus:ring-brand"
      >
        {@label}
      </button>
    </div>
    """
  end

  defp search_hints(assigns) do
    ~H"""
    <div
      id="search-hints"
      class="flex flex-col items-center justify-center rounded-2xl border border-border bg-surface/40 px-4 py-10 text-center sm:py-12"
    >
      <div class="rounded-full bg-surface p-4 mb-4">
        <.icon name="hero-magnifying-glass" class="size-12 text-text-secondary/30" />
      </div>
      <h3 class="text-lg font-medium text-text-primary mb-4">O que você quer assistir?</h3>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 max-w-2xl">
        <div class="flex items-center gap-3 rounded-lg border border-border bg-surface p-4">
          <.icon name="hero-tv" class="size-8 text-brand" />
          <div class="text-left">
            <p class="font-medium text-text-primary">Canais</p>
            <p class="text-sm text-text-secondary">TV ao vivo</p>
          </div>
        </div>
        <div class="flex items-center gap-3 rounded-lg border border-border bg-surface p-4">
          <.icon name="hero-film" class="size-8 text-brand" />
          <div class="text-left">
            <p class="font-medium text-text-primary">Filmes</p>
            <p class="text-sm text-text-secondary">Catálogo VOD</p>
          </div>
        </div>
        <div class="flex items-center gap-3 rounded-lg border border-border bg-surface p-4">
          <.icon name="hero-video-camera" class="size-8 text-brand" />
          <div class="text-left">
            <p class="font-medium text-text-primary">Séries</p>
            <p class="text-sm text-text-secondary">Temporadas e episódios</p>
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
    perform_search(socket, %{channels: @page_size, movies: @page_size, series: @page_size})
  end

  defp perform_search(socket, page_sizes) do
    query = socket.assigns.query
    user_id = socket.assigns.user_id

    if String.trim(query) == "" do
      socket
      |> assign(result_counts: %{channels: 0, movies: 0, series: 0})
      |> assign(has_more: %{channels: false, movies: false, series: false})
      |> assign(loading: false)
      |> assign(searched: false)
      |> reset_result_streams()
    else
      show_adult = socket.assigns.current_scope.user.show_adult_content

      {channels, more_channels?} = search_channels(user_id, query, 0, page_sizes.channels)

      {movies, more_movies?} =
        search_movies(user_id, query, show_adult, 0, page_sizes.movies)

      {series, more_series?} =
        search_series(user_id, query, show_adult, 0, page_sizes.series)

      favorite_ids = search_favorite_ids(user_id, channels, movies, series)

      channels = mark_favorites(channels, favorite_ids.live_channels)
      movies = mark_favorites(movies, favorite_ids.movies)
      series = mark_favorites(series, favorite_ids.series)

      socket
      |> assign(
        result_counts: %{
          channels: length(channels),
          movies: length(movies),
          series: length(series)
        },
        has_more: %{
          channels: more_channels?,
          movies: more_movies?,
          series: more_series?
        },
        loading: false,
        searched: true
      )
      |> stream(:search_channels, channels, reset: true)
      |> stream(:search_movies, movies, reset: true)
      |> stream(:search_series, series, reset: true)
    end
  end

  defp search_channels(user_id, query, offset, page_size) do
    user_id
    |> Iptv.search_channels(query, limit: page_size + 1, offset: offset)
    |> split_page(page_size)
  end

  defp search_movies(user_id, query, show_adult, offset, page_size) do
    user_id
    |> Iptv.search_movies(query,
      limit: page_size + 1,
      offset: offset,
      show_adult: show_adult
    )
    |> split_page(page_size)
  end

  defp search_series(user_id, query, show_adult, offset, page_size) do
    user_id
    |> Iptv.search_series(query,
      limit: page_size + 1,
      offset: offset,
      show_adult: show_adult
    )
    |> split_page(page_size)
  end

  defp split_page(items, page_size) do
    {Enum.take(items, page_size), length(items) > page_size}
  end

  defp load_more_results(socket, result_type) do
    if socket.assigns.has_more[result_type] do
      current_count = socket.assigns.result_counts[result_type]
      {next_page, has_more?} = search_page(socket, result_type, current_count)

      next_page =
        mark_favorites(
          next_page,
          favorite_ids_for(socket.assigns.user_id, result_type, next_page)
        )

      socket
      |> assign(
        result_counts:
          Map.put(socket.assigns.result_counts, result_type, current_count + length(next_page)),
        has_more: Map.put(socket.assigns.has_more, result_type, has_more?)
      )
      |> stream(result_stream(result_type), next_page, at: -1)
    else
      socket
    end
  end

  defp search_page(socket, :channels, offset) do
    search_channels(socket.assigns.user_id, socket.assigns.query, offset, @page_size)
  end

  defp search_page(socket, :movies, offset) do
    search_movies(
      socket.assigns.user_id,
      socket.assigns.query,
      socket.assigns.current_scope.user.show_adult_content,
      offset,
      @page_size
    )
  end

  defp search_page(socket, :series, offset) do
    search_series(
      socket.assigns.user_id,
      socket.assigns.query,
      socket.assigns.current_scope.user.show_adult_content,
      offset,
      @page_size
    )
  end

  defp result_stream(:channels), do: :search_channels
  defp result_stream(:movies), do: :search_movies
  defp result_stream(:series), do: :search_series

  defp favorite_ids_for(user_id, :channels, items) do
    Iptv.list_favorite_ids(user_id, "live_channel", Enum.map(items, & &1.id))
  end

  defp favorite_ids_for(user_id, :movies, items) do
    Iptv.list_favorite_ids(user_id, "movie", Enum.map(items, & &1.id))
  end

  defp favorite_ids_for(user_id, :series, items) do
    Iptv.list_favorite_ids(user_id, "series", Enum.map(items, & &1.id))
  end

  defp search_favorite_ids(user_id, channels, movies, series) do
    %{
      live_channels: Iptv.list_favorite_ids(user_id, "live_channel", Enum.map(channels, & &1.id)),
      movies: Iptv.list_favorite_ids(user_id, "movie", Enum.map(movies, & &1.id)),
      series: Iptv.list_favorite_ids(user_id, "series", Enum.map(series, & &1.id))
    }
  end

  defp mark_favorites(items, favorite_ids) do
    Enum.map(items, &Map.put(&1, :is_favorite, MapSet.member?(favorite_ids, &1.id)))
  end

  defp refresh_after_favorite(socket, {:ok, _status}) do
    page_sizes =
      Map.new(socket.assigns.result_counts, fn {result_type, count} ->
        {result_type, max(count, @page_size)}
      end)

    perform_search(socket, page_sizes)
  end

  defp refresh_after_favorite(socket, {:error, _reason}), do: socket

  defp reset_result_streams(socket) do
    socket
    |> stream(:search_channels, [], reset: true)
    |> stream(:search_movies, [], reset: true)
    |> stream(:search_series, [], reset: true)
  end

  defp has_results?(result_counts) do
    Enum.any?(Map.values(result_counts), &(&1 > 0))
  end

  defp total_count(result_counts), do: result_counts |> Map.values() |> Enum.sum()

  defp result_count_label(count, has_more?) do
    suffix = if has_more?, do: "+", else: ""
    noun = if count == 1, do: "resultado", else: "resultados"

    "#{count}#{suffix} #{noun}"
  end
end
