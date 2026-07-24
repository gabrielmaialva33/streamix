defmodule StreamixWeb.Gindex.MovieDetailLive do
  @moduledoc """
  LiveView for displaying GIndex movie details.
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv
  alias StreamixWeb.Content.FavoriteState
  alias StreamixWeb.Gindex.DetailHelpers, as: DH

  import StreamixWeb.CoreComponents, only: [icon: 1]

  def mount(%{"id" => movie_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])

    case Iptv.get_movie(movie_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: ~p"/gindex/movies")}

      movie ->
        # Verify it's a GIndex movie
        if is_nil(movie.gindex_path) do
          {:ok,
           socket
           |> put_flash(:error, "Filme não pertence ao GIndex")
           |> push_navigate(to: ~p"/gindex/movies")}
        else
          is_favorite = Iptv.favorite?(user_id, "movie", movie.id)
          movie = Iptv.get_movie_with_provider!(movie.id)

          socket =
            socket
            |> assign(page_title: movie.title || movie.name)
            |> assign(
              current_path: with_return_to(~p"/gindex/movies/#{movie.id}", return_to),
              return_to: return_to
            )
            |> assign(movie: movie)
            |> assign(lcp_image: movie.stream_icon)
            |> assign(display_title: DH.display_title_movie(movie))
            |> assign(is_favorite: is_favorite)
            |> assign(user_id: user_id)

          {:ok, socket}
        end
    end
  end

  # Event Handlers

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

  def handle_event("play_movie", _, socket) do
    {:noreply,
     redirect(socket,
       to:
         with_return_to(
           ~p"/watch/gindex/#{socket.assigns.movie.id}",
           socket.assigns.current_path
         )
     )}
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    movie = socket.assigns.movie
    is_favorite = socket.assigns.is_favorite

    result =
      FavoriteState.toggle(user_id, "movie", movie.id, %{
        content_name: movie.title || movie.name,
        content_icon: movie.stream_icon
      })

    {:noreply, assign(socket, is_favorite: FavoriteState.preserve_boolean(is_favorite, result))}
  end

  # Render

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <!-- Hero Section -->
      <div class="relative h-[40vh] sm:h-[50vh] min-h-[260px]">
        <div class="absolute inset-0 overflow-hidden">
          <img
            :if={@movie.stream_icon}
            src={@movie.stream_icon}
            alt=""
            aria-hidden="true"
            class="w-full h-full object-cover scale-110 blur-2xl opacity-60"
            loading="lazy"
            referrerpolicy="no-referrer"
          />
          <div
            :if={is_nil(@movie.stream_icon)}
            class="w-full h-full bg-surface-hover"
          />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        <!-- Back Button -->
        <div class="absolute top-20 left-4 sm:left-6 z-30">
          <.link
            navigate={@return_to || ~p"/browse/movies?source=gindex"}
            class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium focus:outline-none focus:ring-2 focus:ring-brand"
          >
            <.icon name="hero-arrow-left" class="size-3.5 sm:size-4" /> Voltar
          </.link>
        </div>
      </div>
      <!-- Content Section -->
      <div class="relative -mt-24 sm:-mt-32 px-[4%] sm:px-8 lg:px-12 pb-8 sm:pb-12">
        <div class="max-w-5xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-4 sm:gap-6 lg:gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-40 sm:w-48 lg:w-64 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <img
                  :if={@movie.stream_icon}
                  src={@movie.stream_icon}
                  alt={@display_title}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  referrerpolicy="no-referrer"
                />
                <div
                  :if={is_nil(@movie.stream_icon)}
                  class="w-full h-full flex items-center justify-center bg-surface-hover"
                >
                  <.icon name="hero-film" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>
            <!-- Info -->
            <div class="flex-1 space-y-4 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-2">
                <h1
                  class="text-2xl sm:text-3xl lg:text-4xl font-bold text-text-primary leading-tight"
                  title={@movie.name}
                >
                  {@display_title}
                </h1>
                <p
                  :if={@movie.title && @movie.title != @movie.name && @movie.title != @display_title}
                  class="text-lg text-text-secondary"
                >
                  {@movie.title}
                </p>
              </div>
              <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2">
                <span
                  :if={@movie.year}
                  class="inline-flex items-center h-7 px-2.5 bg-surface text-text-primary rounded-md text-sm font-medium"
                >
                  {@movie.year}
                </span>
                <span
                  :if={@movie.rating}
                  class="inline-flex items-center gap-1 h-7 px-2.5 bg-warning/10 text-warning rounded-md text-sm font-medium"
                >
                  <.icon name="hero-star-solid" class="size-3.5" /> {@movie.rating}
                </span>
                <span
                  :if={@movie.container_extension}
                  class="inline-flex items-center h-7 px-2.5 bg-info/10 text-info rounded-md uppercase text-xs font-bold"
                >
                  {@movie.container_extension}
                </span>
              </div>

              <%!-- Plot (enriched) --%>
              <p
                :if={@movie.plot && @movie.plot != ""}
                class="text-sm sm:text-base text-text-secondary leading-relaxed max-w-3xl"
              >
                {@movie.plot}
              </p>
              <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-3 pt-4">
                <button
                  type="button"
                  phx-click="play_movie"
                  class="inline-flex items-center justify-center gap-2 px-6 sm:px-8 py-3 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-sm sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
                >
                  <.icon name="hero-play-solid" class="size-5" /> Assistir
                </button>

                <StreamixWeb.WatchPartyComponents.create_party_button
                  content_type="gindex"
                  content_id={@movie.id}
                />

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-12 h-12 rounded-lg border-2 transition-all focus:outline-none focus:ring-2 focus:ring-brand",
                    @is_favorite && "bg-brand border-brand text-white",
                    !@is_favorite &&
                      "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
                  ]}
                  aria-label={
                    if @is_favorite, do: "Remover dos favoritos", else: "Adicionar aos favoritos"
                  }
                >
                  <.icon
                    name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                    class="size-5"
                  />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path
  end

  defp safe_return_path(_path), do: nil
end
