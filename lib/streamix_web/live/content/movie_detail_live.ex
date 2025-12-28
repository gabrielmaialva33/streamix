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
    # Refetch if missing basic info OR if missing new extended metadata
    missing_basic = is_nil(movie.plot) and is_nil(movie.cast) and is_nil(movie.director)
    missing_extended = is_nil(movie.content_rating) and is_nil(movie.tagline)

    missing_basic or missing_extended
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
    <div class="min-h-screen bg-background">
      <!-- Hero Section -->
      <div class="relative h-[40vh] sm:h-[50vh] lg:h-[60vh] min-h-[280px] sm:min-h-[400px]">
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

        <div class="absolute inset-0 bg-gradient-to-t from-background via-background/60 to-transparent" />
        <div class="absolute inset-0 bg-gradient-to-r from-background via-background/30 to-transparent" />
        
    <!-- Back Button -->
        <div class="absolute top-4 left-4 sm:top-6 sm:left-6 z-10">
          <.link
            navigate={back_path(@mode, @provider)}
            class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-1.5 sm:py-2 bg-black/40 backdrop-blur-sm text-white/90 hover:text-white hover:bg-black/60 rounded-full transition-all text-xs sm:text-sm font-medium"
          >
            <.icon name="hero-arrow-left" class="size-3.5 sm:size-4" /> Voltar
          </.link>
        </div>
      </div>
      
    <!-- Content Section -->
      <div class="relative -mt-24 sm:-mt-32 lg:-mt-40 px-[4%] sm:px-8 lg:px-12 pb-8 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-4 sm:gap-6 lg:gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-32 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10">
                <img
                  :if={@movie.stream_icon}
                  src={@movie.stream_icon}
                  alt={@movie.name}
                  class="w-full h-full object-cover"
                />
                <div
                  :if={!@movie.stream_icon}
                  class="w-full h-full bg-surface flex items-center justify-center"
                >
                  <.icon name="hero-film" class="size-12 sm:size-20 text-text-secondary/30" />
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-3 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-1 sm:space-y-2">
                <h1 class="text-xl sm:text-3xl lg:text-5xl font-bold text-text-primary leading-tight">
                  {@movie.title || @movie.name}
                </h1>
                <p
                  :if={@movie.title && @movie.name && @movie.title != @movie.name}
                  class="text-sm sm:text-lg text-text-secondary"
                >
                  {@movie.name}
                </p>
                <!-- Tagline -->
                <p
                  :if={@movie.tagline && @movie.tagline != ""}
                  class="text-sm sm:text-lg italic text-text-secondary/80"
                >
                  "{@movie.tagline}"
                </p>
              </div>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <!-- Content Rating -->
                <span
                  :if={@movie.content_rating}
                  class={[
                    "inline-flex items-center justify-center min-w-[36px] sm:min-w-[42px] h-6 sm:h-8 px-2 sm:px-2.5 rounded-md text-[10px] sm:text-xs font-bold",
                    content_rating_class(@movie.content_rating)
                  ]}
                  title="Classificação Indicativa"
                >
                  {@movie.content_rating}
                </span>
                <span
                  :if={@movie.rating}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-yellow-500/20 text-yellow-400 rounded-md text-xs sm:text-sm font-semibold"
                >
                  <.icon name="hero-star-solid" class="size-3 sm:size-3.5" />
                  {format_rating(@movie.rating)}
                </span>
                <span
                  :if={@movie.year}
                  class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-primary rounded-md text-xs sm:text-sm font-medium"
                >
                  {@movie.year}
                </span>
                <span
                  :if={@movie.duration}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
                >
                  <.icon name="hero-clock" class="size-3 sm:size-3.5" />{format_duration(
                    @movie.duration
                  )}
                </span>
                <span
                  :if={@movie.container_extension}
                  class="inline-flex items-center h-6 sm:h-8 px-2 sm:px-2.5 bg-brand/20 text-brand rounded-md uppercase text-[10px] sm:text-xs font-bold"
                >
                  {@movie.container_extension}
                </span>
              </div>
              
    <!-- Genres -->
              <div
                :if={@movie.genre}
                class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2"
              >
                <span
                  :for={genre <- split_genres(@movie.genre)}
                  class="px-2 sm:px-3 py-0.5 sm:py-1 bg-white/5 text-text-secondary rounded-full text-xs sm:text-sm border border-white/10 hover:border-white/20 transition-colors"
                >
                  {genre}
                </span>
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <button
                  type="button"
                  phx-click="play_movie"
                  class="inline-flex items-center justify-center gap-2 w-full sm:w-auto px-6 sm:px-8 py-3 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-lg shadow-brand/30 text-sm sm:text-base"
                >
                  <.icon name="hero-play-solid" class="size-4 sm:size-5" /> Assistir Agora
                </button>

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-10 h-10 sm:w-12 sm:h-12 rounded-lg border-2 transition-all",
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
                    class="size-4 sm:size-5"
                  />
                </button>

                <a
                  :if={@movie.youtube_trailer}
                  href={trailer_url(@movie.youtube_trailer)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-5 py-2.5 sm:py-3 bg-surface border border-border text-text-primary font-semibold rounded-lg hover:bg-surface-hover transition-colors text-sm"
                >
                  <.icon name="hero-play-circle" class="size-4 sm:size-5 text-red-500" /> Trailer
                </a>

                <a
                  :if={@movie.tmdb_id}
                  href={"https://www.themoviedb.org/movie/#{@movie.tmdb_id}"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-1.5 sm:gap-2 px-3 sm:px-4 py-2.5 sm:py-3 bg-surface border border-border text-text-secondary rounded-lg hover:text-text-primary hover:bg-surface-hover transition-colors text-xs sm:text-sm"
                  title="Ver no The Movie Database"
                >
                  <svg class="size-3.5 sm:size-4" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
                  </svg>
                  TMDB
                </a>
              </div>
              
    <!-- Synopsis -->
              <div :if={@movie.plot} class="pt-2 sm:pt-4">
                <h3 class="text-base sm:text-lg font-semibold text-text-primary mb-2 sm:mb-3">
                  Sinopse
                </h3>
                <p class="text-text-secondary text-sm sm:text-base leading-relaxed">
                  {@movie.plot}
                </p>
              </div>
              
    <!-- Details Grid -->
              <div
                :if={@movie.director || @movie.cast}
                class="grid sm:grid-cols-2 gap-4 sm:gap-6 pt-2 sm:pt-4"
              >
                <div :if={@movie.director} class="space-y-1 sm:space-y-2">
                  <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
                    Direção
                  </h4>
                  <p class="text-text-primary text-sm sm:text-base">{@movie.director}</p>
                </div>

                <div :if={@movie.cast} class="space-y-1 sm:space-y-2">
                  <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
                    Elenco
                  </h4>
                  <p class="text-text-primary text-sm sm:text-base">{truncate_cast(@movie.cast)}</p>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Image Gallery -->
          <div :if={@movie.images && @movie.images != []} class="mt-8 sm:mt-12">
            <h3 class="text-lg sm:text-xl font-semibold text-text-primary mb-3 sm:mb-4">Galeria</h3>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-2 sm:gap-3">
              <div
                :for={image <- @movie.images}
                class="aspect-video rounded-lg overflow-hidden bg-surface-hover cursor-pointer hover:ring-2 hover:ring-brand transition-all group"
              >
                <img
                  src={image}
                  alt="Imagem do filme"
                  class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                  loading="lazy"
                />
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

  defp split_genres(nil), do: []

  defp split_genres(genre) when is_binary(genre) do
    genre
    |> String.split(~r/[,\/]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
  end

  defp truncate_cast(nil), do: nil

  defp truncate_cast(cast) when is_binary(cast) do
    cast
    |> String.split(",")
    |> Enum.take(5)
    |> Enum.map_join(", ", &String.trim/1)
  end

  defp format_duration(nil), do: nil

  defp format_duration(duration) when is_binary(duration) do
    # Try to parse as minutes if it's just a number
    case Integer.parse(duration) do
      {minutes, ""} when minutes > 0 ->
        hours = div(minutes, 60)
        mins = rem(minutes, 60)

        cond do
          hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
          hours > 0 -> "#{hours}h"
          true -> "#{mins}min"
        end

      _ ->
        # Already formatted or unparseable, return as-is
        duration
    end
  end

  defp format_duration(duration) when is_integer(duration) do
    hours = div(duration, 60)
    mins = rem(duration, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}min"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}min"
    end
  end

  defp format_duration(_), do: nil

  # Content rating color classes based on Brazilian/US ratings
  defp content_rating_class(rating) when is_binary(rating) do
    rating_upper = String.upcase(rating)

    cond do
      # Livre / General (green)
      rating_upper in ["L", "G", "TV-G", "TV-Y", "TV-Y7"] ->
        "bg-green-500/20 text-green-400"

      # 10 anos / PG (blue)
      rating_upper in ["10", "PG", "TV-PG"] ->
        "bg-blue-500/20 text-blue-400"

      # 12 anos / PG-13 (yellow)
      rating_upper in ["12", "PG-13", "TV-14"] ->
        "bg-yellow-500/20 text-yellow-400"

      # 14 anos (orange)
      rating_upper in ["14"] ->
        "bg-orange-500/20 text-orange-400"

      # 16 anos (red-orange)
      rating_upper in ["16", "R", "TV-MA"] ->
        "bg-red-400/20 text-red-400"

      # 18 anos / NC-17 (dark red)
      rating_upper in ["18", "NC-17"] ->
        "bg-red-600/20 text-red-500"

      # Default
      true ->
        "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"
end
