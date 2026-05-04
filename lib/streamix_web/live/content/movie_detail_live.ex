defmodule StreamixWeb.Content.MovieDetailLive do
  @moduledoc """
  LiveView for displaying movie details before playback.
  Works for both /browse/movies/:id (global provider) and /providers/:id/movies/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Access
  alias Streamix.AI.SemanticSearch
  alias Streamix.Iptv
  alias Streamix.Iptv.Movie
  alias StreamixWeb.PlayerHelpers

  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Content.DetailComponents, only: [gallery_preview: 1]

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
    user = socket.assigns.current_scope.user

    case Iptv.get_movie(movie_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: back_path(mode, provider))}

      movie ->
        is_favorite = Iptv.is_favorite?(user_id, "movie", movie.id)
        movie = maybe_fetch_movie_info(movie)

        # Prewarm the upstream redirect chain in the background. The
        # user is on the detail page now and will likely click play in
        # a few seconds — by then the resolution is cached.
        if connected?(socket) do
          PlayerHelpers.prewarm_upstream_redirect("movie", movie, user_id)
        end

        current_path =
          if mode == :browse,
            do: "/browse/movies/#{movie.id}",
            else: "/providers/#{provider.id}/movies/#{movie.id}"

        # Load similar movies (async-safe, returns [] on error)
        similar_movies = load_similar_movies(movie.id)

        socket =
          socket
          |> assign(page_title: movie.title || movie.name)
          |> assign(
            page_description: movie.plot || "Assista #{movie.title || movie.name} no Streamix"
          )
          |> assign(og_image: og_image_url(movie))
          |> assign(current_path: current_path)
          |> assign(provider: provider)
          |> assign(premium_access: Access.can_play_global_content?(user, provider))
          |> assign(movie: movie)
          |> assign(lcp_image: get_backdrop(movie) || maybe_proxy(movie.stream_icon))
          |> assign(mode: mode)
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)
          |> assign(similar_movies: similar_movies)
          |> assign(selected_gallery_image: nil)

        {:ok, socket}
    end
  end

  defp load_similar_movies(movie_id) do
    case SemanticSearch.similar(movie_id, :movies, limit: 6) do
      {:ok, results} ->
        # Fetch full movie data for results
        movie_ids = Enum.map(results, & &1.id)
        Iptv.get_movies_by_ids(movie_ids)

      {:error, reason} ->
        require Logger
        Logger.debug("[MovieDetail] SemanticSearch unavailable: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      require Logger
      Logger.warning("[MovieDetail] Unexpected error in load_similar_movies: #{inspect(e)}")
      []
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
    missing_basic = is_nil(movie.plot)
    missing_extended = is_nil(movie.content_rating) and is_nil(movie.tagline)

    missing_basic or missing_extended
  end

  # ============================================
  # Event Handlers
  # ============================================

  # ThemeToggle hook event (client-side theme management, no server action needed)
  def handle_event("theme_init", _params, socket), do: {:noreply, socket}

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

  def handle_event("open_gallery_image", %{"src" => image}, socket) do
    {:noreply, assign(socket, selected_gallery_image: image)}
  end

  def handle_event("close_gallery_preview", _, socket) do
    {:noreply, assign(socket, selected_gallery_image: nil)}
  end

  # ============================================
  # Render
  # ============================================

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-background">
      <!-- Hero Section -->
      <div class="relative h-[30vh] sm:h-[50vh] lg:h-[60vh] min-h-[200px] sm:min-h-[400px]">
        <div id={"detail-hero-#{@movie.id}"} phx-hook="ImageFallback" class="absolute inset-0">
          <img
            :if={get_backdrop(@movie) || @movie.stream_icon}
            src={get_backdrop(@movie) || ImageProxy.proxy(@movie.stream_icon)}
            alt={@movie.name}
            class="w-full h-full object-cover"
            data-fallback-target
            fetchpriority="high"
            decoding="async"
          />
          <div
            data-fallback
            class={[
              "w-full h-full bg-gradient-to-br from-neutral-800 to-neutral-900",
              (get_backdrop(@movie) || @movie.stream_icon) && "hidden"
            ]}
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
      <div class="relative -mt-16 sm:-mt-32 lg:-mt-40 px-3 sm:px-8 lg:px-12 pb-6 sm:pb-12">
        <div class="max-w-7xl mx-auto">
          <div class="flex flex-col lg:flex-row gap-3 sm:gap-6 lg:gap-8">
            <!-- Poster -->
            <div class="flex-shrink-0 w-24 sm:w-48 lg:w-72 mx-auto lg:mx-0">
              <div
                id={"detail-poster-#{@movie.id}"}
                phx-hook="ImageFallback"
                class="aspect-[2/3] rounded-lg sm:rounded-xl overflow-hidden shadow-2xl ring-1 ring-white/10"
              >
                <img
                  :if={@movie.stream_icon}
                  src={ImageProxy.proxy(@movie.stream_icon)}
                  alt={@movie.name}
                  class="w-full h-full object-cover"
                  data-fallback-target
                  loading="lazy"
                  decoding="async"
                />
                <div
                  data-fallback
                  class={[
                    "w-full h-full bg-gradient-to-br from-zinc-800 to-zinc-900 flex flex-col items-center justify-center p-4 text-center",
                    @movie.stream_icon && "hidden"
                  ]}
                >
                  <.icon name="hero-film" class="size-10 sm:size-16 text-brand/50 mb-2 sm:mb-3" />
                  <span class="text-xs sm:text-sm text-text-muted leading-tight line-clamp-3">
                    {@movie.title || @movie.name}
                  </span>
                </div>
              </div>
            </div>
            
    <!-- Info -->
            <div class="flex-1 space-y-2 sm:space-y-4 lg:space-y-6 text-center lg:text-left">
              <!-- Title -->
              <div class="space-y-1 sm:space-y-2">
                <h1 class="text-lg sm:text-3xl lg:text-5xl font-bold text-text-primary leading-tight">
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

              <div :if={@mode == :browse and not @premium_access} data-premium-badge>
                <.premium_badge />
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
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-warning/10 text-warning rounded-md text-xs sm:text-sm font-semibold"
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
                  :if={@movie.duration_secs}
                  class="inline-flex items-center gap-1 h-6 sm:h-8 px-2 sm:px-2.5 bg-surface text-text-secondary rounded-md text-xs sm:text-sm"
                >
                  <.icon name="hero-clock" class="size-3 sm:size-3.5" />{format_duration(
                    @movie.duration_secs
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
                :if={@movie.genres != []}
                class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2"
              >
                <span
                  :for={genre <- @movie.genres}
                  class="px-2 sm:px-3 py-0.5 sm:py-1 bg-white/5 text-text-secondary rounded-full text-xs sm:text-sm border border-white/10 hover:border-white/20 transition-colors"
                >
                  {genre.name}
                </span>
              </div>
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <button
                  type="button"
                  phx-click="play_movie"
                  class="inline-flex items-center justify-center gap-1.5 w-full sm:w-auto px-4 sm:px-8 py-2.5 sm:py-3.5 bg-brand text-white font-bold rounded-lg hover:bg-brand-hover transition-colors shadow-card text-xs sm:text-base focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
                >
                  <.icon name="hero-play-solid" class="size-4 sm:size-5" /> Assistir Agora
                </button>

                <StreamixWeb.WatchPartyComponents.create_party_button
                  content_type="movie"
                  content_id={@movie.id}
                />

                <button
                  type="button"
                  phx-click="toggle_favorite"
                  class={[
                    "inline-flex items-center justify-center w-10 h-10 sm:w-12 sm:h-12 rounded-lg border-2 transition-all focus:outline-none focus:ring-2 focus:ring-brand",
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
                  <.icon name="hero-play-circle" class="size-4 sm:size-5 text-brand" /> Trailer
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

              <.premium_cta_banner
                :if={@mode == :browse and not @premium_access}
                id="movie-detail-premium-cta"
                current_scope={@current_scope}
              />
              
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
                :if={director_names(@movie) != "" or cast_names(@movie) != ""}
                class="grid sm:grid-cols-2 gap-4 sm:gap-6 pt-2 sm:pt-4"
              >
                <div :if={director_names(@movie) != ""} class="space-y-1 sm:space-y-2">
                  <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
                    Direção
                  </h4>
                  <p class="text-text-primary text-sm sm:text-base">{director_names(@movie)}</p>
                </div>

                <div :if={cast_names(@movie) != ""} class="space-y-1 sm:space-y-2">
                  <h4 class="text-xs sm:text-sm font-semibold text-text-secondary uppercase tracking-wide">
                    Elenco
                  </h4>
                  <p class="text-text-primary text-sm sm:text-base">
                    {truncate_cast(cast_names(@movie))}
                  </p>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Image Gallery -->
          <div :if={Movie.has_images?(@movie)} class="mt-8 sm:mt-12">
            <h3 class="text-lg sm:text-xl font-semibold text-text-primary mb-3 sm:mb-4">Galeria</h3>
            <div class="responsive-gallery-grid">
              <button
                :for={image <- Movie.image_urls(@movie)}
                type="button"
                phx-click="open_gallery_image"
                phx-value-src={image}
                class="aspect-video rounded-lg overflow-hidden bg-surface-hover cursor-pointer hover:ring-2 hover:ring-brand transition-all group focus:outline-none focus:ring-2 focus:ring-brand"
                aria-label="Abrir imagem da galeria"
              >
                <img
                  src={image}
                  alt="Imagem do filme"
                  class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                  loading="lazy"
                  decoding="async"
                />
              </button>
            </div>
          </div>
          
    <!-- Similar Movies -->
          <div :if={@similar_movies != []} class="mt-8 sm:mt-12">
            <h3 class="text-lg sm:text-xl font-semibold text-text-primary mb-3 sm:mb-4">
              Títulos Similares
            </h3>
            <div class="grid grid-cols-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 gap-2 sm:gap-4">
              <.link
                :for={similar <- @similar_movies}
                navigate={similar_movie_path(@mode, @provider, similar)}
                class="group block transition-all duration-300"
              >
                <div
                  id={"similar-img-#{similar.id}"}
                  phx-hook="ImageFallback"
                  class="aspect-[2/3] bg-surface-hover relative rounded-md sm:rounded-lg overflow-hidden shadow-sm group-hover:shadow-xl group-hover:shadow-brand/20 transition-all duration-300 group-hover:-translate-y-1 block"
                >
                  <img
                    :if={similar.stream_icon}
                    src={ImageProxy.proxy(similar.stream_icon)}
                    alt={similar.title || similar.name}
                    class="w-full h-full object-cover transition-transform duration-300"
                    loading="lazy"
                    decoding="async"
                    data-fallback-target
                  />
                  <div
                    data-fallback
                    class={[
                      "w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-zinc-800 to-zinc-900 p-2 text-center",
                      similar.stream_icon && "hidden"
                    ]}
                  >
                    <.icon name="hero-film" class="size-6 text-brand/60 mb-1" />
                    <span class="text-[9px] text-text-muted leading-tight line-clamp-2">
                      {similar.title || similar.name}
                    </span>
                  </div>
                </div>
                <div class="px-0.5 pt-1.5 sm:pt-2">
                  <p class="text-[11px] sm:text-sm text-text-primary font-medium truncate group-hover:text-brand transition-colors mt-0.5">
                    {similar.title || similar.name}
                  </p>
                  <p :if={similar.year} class="text-[10px] sm:text-xs text-text-secondary">
                    {similar.year}
                  </p>
                </div>
              </.link>
            </div>
          </div>
        </div>
      </div>
      <.gallery_preview image={@selected_gallery_image} alt="Imagem do filme" />
    </div>
    """
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp og_image_url(%Movie{} = movie) do
    case Movie.backdrop_urls(movie) do
      [url | _] -> url
      _ -> og_image_url_fallback(movie)
    end
  end

  defp og_image_url_fallback(%{stream_icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp og_image_url_fallback(_), do: nil

  defp back_path(:browse, _provider), do: ~p"/browse/movies"
  defp back_path(:provider, provider), do: ~p"/providers/#{provider.id}/movies"

  defp similar_movie_path(:browse, _provider, movie), do: ~p"/browse/movies/#{movie.id}"

  defp similar_movie_path(:provider, provider, movie),
    do: ~p"/providers/#{provider.id}/movies/#{movie.id}"

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

  defp get_backdrop(%Movie{} = movie) do
    case Movie.backdrop_urls(movie) do
      [url | _] -> ImageProxy.proxy(url)
      _ -> nil
    end
  end

  defp get_backdrop(_), do: nil

  defp maybe_proxy(nil), do: nil
  defp maybe_proxy(url) when is_binary(url), do: ImageProxy.proxy(url)

  defp trailer_url(youtube_id) when is_binary(youtube_id) do
    if String.contains?(youtube_id, "youtube.com") or String.contains?(youtube_id, "youtu.be") do
      youtube_id
    else
      "https://www.youtube.com/watch?v=#{youtube_id}"
    end
  end

  defp trailer_url(_), do: nil

  defp cast_names(%{credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.role == "cast"))
    |> Enum.sort_by(& &1.position)
    |> Enum.map_join(", ", & &1.person.name)
  end

  defp cast_names(_), do: ""

  defp director_names(%{credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.role == "director"))
    |> Enum.map_join(", ", & &1.person.name)
  end

  defp director_names(_), do: ""

  defp truncate_cast(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.take(5)
    |> Enum.map_join(", ", &String.trim/1)
  end

  defp truncate_cast(_), do: ""

  defp format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    total_minutes = div(seconds, 60)
    hours = div(total_minutes, 60)
    mins = rem(total_minutes, 60)

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
        "bg-success/10 text-success"

      # 10 anos / PG (blue)
      rating_upper in ["10", "PG", "TV-PG"] ->
        "bg-info/10 text-info"

      # 12 anos / PG-13 (yellow)
      rating_upper in ["12", "PG-13", "TV-14"] ->
        "bg-warning/10 text-warning"

      # 14 anos (orange)
      rating_upper in ["14"] ->
        "bg-warning/15 text-warning"

      # 16 anos (red-orange)
      rating_upper in ["16", "R", "TV-MA"] ->
        "bg-error/10 text-error"

      # 18 anos / NC-17 (dark red)
      rating_upper in ["18", "NC-17"] ->
        "bg-error/15 text-error"

      # Default
      true ->
        "bg-surface text-text-secondary"
    end
  end

  defp content_rating_class(_), do: "bg-surface text-text-secondary"
end
