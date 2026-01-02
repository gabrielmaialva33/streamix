defmodule StreamixWeb.Gindex.MovieDetailLive do
  @moduledoc """
  LiveView for displaying GIndex movie details.
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  def mount(%{"id" => movie_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

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
          is_favorite = Iptv.is_favorite?(user_id, "movie", movie.id)
          movie = Iptv.get_movie_with_provider!(movie.id)

          socket =
            socket
            |> assign(page_title: movie.title || movie.name)
            |> assign(current_path: "/gindex/movies/#{movie.id}")
            |> assign(movie: movie)
            |> assign(is_favorite: is_favorite)
            |> assign(user_id: user_id)

          {:ok, socket}
        end
    end
  end

  # Event Handlers

  def handle_event("play_movie", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/gindex/#{socket.assigns.movie.id}")}
  end

  def handle_event("toggle_favorite", _, socket) do
    user_id = socket.assigns.user_id
    movie = socket.assigns.movie
    is_favorite = socket.assigns.is_favorite

    if is_favorite do
      Iptv.remove_favorite(user_id, "movie", movie.id)
    else
      Iptv.add_favorite(user_id, %{
        content_type: "movie",
        content_id: movie.id,
        content_name: movie.title || movie.name,
        content_icon: movie.stream_icon
      })
    end

    {:noreply, assign(socket, is_favorite: !is_favorite)}
  end

  # Render

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <!-- Hero Section -->
      <div class="relative h-[40vh] sm:h-[50vh] min-h-[280px]">
        <div class="absolute inset-0">
          <div class="w-full h-full bg-gradient-to-br from-purple-900 to-gray-900" />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        
    <!-- Back Button -->
        <div class="absolute top-4 left-4 sm:top-6 sm:left-6 z-10">
          <.link
            navigate={~p"/gindex/movies"}
            class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium"
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
            <div class="flex-shrink-0 w-32 sm:w-48 lg:w-64 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg overflow-hidden shadow-2xl ring-1 ring-white/10 bg-surface">
                <div class="w-full h-full flex items-center justify-center">
                  <.icon name="hero-film" class="size-12 sm:size-16 text-text-secondary/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-4 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-2">
                <h1 class="text-xl sm:text-3xl lg:text-4xl font-bold text-text-primary leading-tight">
                  {@movie.name}
                </h1>
                <p
                  :if={@movie.title && @movie.title != @movie.name}
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
                  :if={@movie.container_extension}
                  class="inline-flex items-center h-7 px-2.5 bg-purple-600/20 text-purple-400 rounded-md uppercase text-xs font-bold"
                >
                  {@movie.container_extension}
                </span>
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-3 pt-4">
                <button
                  type="button"
                  phx-click="play_movie"
                  class="inline-flex items-center justify-center gap-2 px-6 sm:px-8 py-3 bg-purple-600 text-white font-bold rounded-lg hover:bg-purple-700 transition-colors shadow-lg shadow-purple-600/30 text-sm sm:text-base"
                >
                  <.icon name="hero-play-solid" class="size-5" /> Assistir
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-12 h-12 rounded-lg border-2 transition-all",
                    @is_favorite && "bg-red-600 border-red-600 text-white",
                    !@is_favorite &&
                      "border-border text-text-secondary hover:border-text-secondary hover:text-text-primary bg-surface"
                  ]}
                  title={
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
end
