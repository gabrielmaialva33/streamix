defmodule StreamixWeb.Content.MovieDetailLive do
  @moduledoc """
  LiveView for displaying movie details before playback.
  Works for both /browse/movies/:id (global provider) and /providers/:id/movies/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv

  import StreamixWeb.CoreComponents, only: [icon: 1]

  # Mount for /browse/movies/:id (global provider)
  def mount(%{"id" => movie_id}, _session, socket)
      when not is_map_key(socket.assigns, :provider) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_global_provider()

    if provider do
      mount_with_provider(socket, provider, movie_id, user_id, :browse)
    else
      {:ok,
       socket
       |> put_flash(:error, "Catálogo não disponível")
       |> push_navigate(to: ~p"/providers")}
    end
  end

  # Mount for /providers/:provider_id/movies/:id (user provider)
  def mount(%{"provider_id" => provider_id, "id" => movie_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    provider = Iptv.get_playable_provider(user_id, provider_id)

    if provider do
      mount_with_provider(socket, provider, movie_id, user_id, :provider)
    else
      {:ok,
       socket
       |> put_flash(:error, "Provedor não encontrado")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_with_provider(socket, provider, movie_id, user_id, mode) do
    case Iptv.get_movie(movie_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: back_path(mode, provider))}

      movie ->
        is_favorite = Iptv.is_favorite?(user_id, "movie", movie.id)
        movie = maybe_fetch_movie_info(movie)

        current_path =
          if mode == :browse,
            do: "/browse/movies/#{movie.id}",
            else: "/providers/#{provider.id}/movies/#{movie.id}"

        socket =
          socket
          |> assign(page_title: movie.title || movie.name)
          |> assign(current_path: current_path)
          |> assign(provider: provider)
          |> assign(movie: movie)
          |> assign(mode: mode)
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)

        {:ok, socket}
    end
  end

  defp maybe_fetch_movie_info(movie) do
    if needs_detailed_info?(movie) do
      case Iptv.fetch_movie_info(movie) do
        {:ok, updated_movie} -> updated_movie
        {:error, _reason} -> movie
      end
    else
      movie
    end
  end

  defp needs_detailed_info?(movie) do
    is_nil(movie.plot) and is_nil(movie.cast) and is_nil(movie.director)
  end

  # ============================================
  # Event Handlers
  # ============================================

  def handle_event("play_movie", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/watch/movie/#{socket.assigns.movie.id}")}
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

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="relative h-[70vh] min-h-[500px]">
        <div class="absolute inset-0">
          <img
            :if={get_backdrop(@movie) || @movie.stream_icon}
            src={get_backdrop(@movie) || @movie.stream_icon}
            alt={@movie.name}
            class="w-full h-full object-cover"
          />
          <div
            :if={!get_backdrop(@movie) && !@movie.stream_icon}
            class="w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900"
          />
        </div>

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/80 to-background/20" />
        <div class="absolute inset-0 bg-gradient-to-r from-background/90 via-background/40 to-transparent" />

        <div class="absolute bottom-0 left-0 right-0 p-6 sm:p-10">
          <div class="flex gap-8 max-w-6xl">
            <div class="hidden md:block flex-shrink-0 w-64">
              <div class="aspect-[2/3] rounded-lg overflow-hidden shadow-2xl">
                <img
                  :if={@movie.stream_icon}
                  src={@movie.stream_icon}
                  alt={@movie.name}
                  class="w-full h-full object-cover"
                />
                <div
                  :if={!@movie.stream_icon}
                  class="w-full h-full bg-neutral-800 flex items-center justify-center"
                >
                  <.icon name="hero-film" class="size-20 text-white/20" />
                </div>
              </div>
            </div>

            <div class="flex-1 space-y-5">
              <.link
                navigate={back_path(@mode, @provider)}
                class="inline-flex items-center gap-2 text-sm text-white/70 hover:text-white transition-colors"
              >
                <.icon name="hero-arrow-left" class="size-4" /> Voltar para Filmes
              </.link>

              <h1 class="text-4xl sm:text-5xl font-bold text-white drop-shadow-2xl">
                {@movie.title || @movie.name}
              </h1>

              <div class="flex flex-wrap items-center gap-3 text-sm">
                <span :if={@movie.year} class="text-white/80">{@movie.year}</span>
                <span
                  :if={@movie.rating}
                  class="flex items-center gap-1 px-2 py-0.5 bg-yellow-500/20 text-yellow-400 rounded"
                >
                  <.icon name="hero-star-solid" class="size-4" />
                  {format_rating(@movie.rating)}
                </span>
                <span :if={@movie.genre} class="px-2 py-0.5 bg-white/10 text-white/80 rounded">
                  {@movie.genre}
                </span>
                <span :if={@movie.duration} class="text-white/60">{@movie.duration}</span>
                <span
                  :if={@movie.container_extension}
                  class="px-2 py-0.5 bg-white/10 text-white/60 rounded uppercase text-xs"
                >
                  {@movie.container_extension}
                </span>
              </div>

              <p :if={@movie.plot} class="text-white/70 text-base leading-relaxed max-w-2xl">
                {@movie.plot}
              </p>

              <div :if={@movie.director || @movie.cast} class="space-y-2 text-sm">
                <p :if={@movie.director} class="text-white/60">
                  <span class="text-white/40">Diretor:</span> {@movie.director}
                </p>
                <p :if={@movie.cast} class="text-white/60">
                  <span class="text-white/40">Elenco:</span> {@movie.cast}
                </p>
              </div>

              <div class="flex items-center gap-4 pt-2">
                <button
                  type="button"
                  phx-click="play_movie"
                  class="inline-flex items-center gap-2 px-8 py-3.5 bg-white text-black font-bold rounded hover:bg-white/90 transition-colors"
                >
                  <.icon name="hero-play-solid" class="size-6" /> Assistir
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-12 h-12 rounded-full border-2 transition-colors",
                    @is_favorite && "bg-red-600 border-red-600 text-white",
                    !@is_favorite && "border-white/40 text-white hover:border-white"
                  ]}
                >
                  <.icon
                    name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
                    class="size-6"
                  />
                </button>

                <a
                  :if={@movie.youtube_trailer}
                  href={trailer_url(@movie.youtube_trailer)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 px-6 py-3 border-2 border-white/40 text-white font-semibold rounded hover:border-white transition-colors"
                >
                  <.icon name="hero-play-circle" class="size-5" /> Trailer
                </a>

                <a
                  :if={@movie.tmdb_id}
                  href={"https://www.themoviedb.org/movie/#{@movie.tmdb_id}"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-2 px-4 py-3 border-2 border-white/20 text-white/70 rounded hover:border-white/40 hover:text-white transition-colors text-sm"
                >
                  TMDB
                </a>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp back_path(:browse, _provider), do: ~p"/browse/movies"
  defp back_path(:provider, provider), do: ~p"/providers/#{provider.id}/movies"

  defp format_rating(%Decimal{} = rating) do
    rating
    |> Decimal.div(2)
    |> Decimal.round(1)
    |> Decimal.to_string()
  end

  defp format_rating(rating) when is_number(rating) do
    Float.round(rating / 2, 1) |> to_string()
  end

  defp format_rating(_), do: nil

  defp get_backdrop(%{backdrop_path: [url | _]}) when is_binary(url), do: url
  defp get_backdrop(_), do: nil

  defp trailer_url(youtube_id) when is_binary(youtube_id) do
    if String.contains?(youtube_id, "youtube.com") or String.contains?(youtube_id, "youtu.be") do
      youtube_id
    else
      "https://www.youtube.com/watch?v=#{youtube_id}"
    end
  end

  defp trailer_url(_), do: nil
end
