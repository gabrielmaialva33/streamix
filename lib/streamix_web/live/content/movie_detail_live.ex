defmodule StreamixWeb.Content.MovieDetailLive do
  @moduledoc """
  LiveView for displaying movie details before playback.
  Works for both /browse/movies/:id (global provider) and /providers/:id/movies/:id (user provider).
  """
  use StreamixWeb, :live_view

  alias Streamix.Iptv.Movie
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.PlayerHelpers

  import StreamixWeb.CoreComponents, only: [icon: 1]

  import StreamixWeb.Content.DetailComponents,
    only: [
      content_rating_badge: 1,
      credits_grid: 1,
      detail_hero: 1,
      detail_title: 1,
      duration_badge: 1,
      extension_badge: 1,
      favorite_button: 1,
      gallery_preview: 1,
      genre_chips: 1,
      image_gallery: 1,
      play_button: 1,
      rating_badge: 1,
      similar_grid: 1,
      synopsis_section: 1,
      tmdb_link: 1,
      trailer_link: 1,
      year_badge: 1
    ]

  # Mount for /providers/:provider_id/movies/:id (user provider). Must
  # come first: the browse clause's pattern also matches these params.
  def mount(%{"provider_id" => _, "id" => movie_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    Detail.with_provider(socket, :provider, params, fn provider ->
      mount_with_provider(socket, provider, movie_id, user_id, :provider)
    end)
  end

  # Mount for /browse/movies/:id (global provider)
  def mount(%{"id" => movie_id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    Detail.with_provider(socket, :browse, %{}, fn provider ->
      mount_with_provider(socket, provider, movie_id, user_id, :browse)
    end)
  end

  defp mount_with_provider(socket, provider, movie_id, user_id, mode) do
    user = socket.assigns.current_scope.user

    case Detail.get_movie(movie_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: back_path(mode, provider))}

      movie ->
        is_favorite = Detail.favorite?(user_id, "movie", movie.id)
        movie = Detail.maybe_fetch_movie_info(movie)

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

        socket =
          socket
          |> assign(page_title: movie.title || movie.name)
          |> assign(
            page_description: movie.plot || "Assista #{movie.title || movie.name} no Streamix"
          )
          |> assign(og_image: og_image_url(movie))
          |> assign(current_path: current_path)
          |> assign(provider: provider)
          |> assign(premium_access: Detail.premium_access?(user, provider))
          |> assign(movie: movie)
          |> assign(lcp_image: Detail.hero_image(movie, movie.stream_icon))
          |> assign(mode: mode)
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)
          |> assign(similar_movies: Detail.similar_movies(movie.id))
          |> assign(selected_gallery_image: nil)

        {:ok, socket}
    end
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

    {:noreply,
     assign(socket, is_favorite: Detail.toggle_movie_favorite(user_id, movie, is_favorite))}
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
      <.detail_hero
        id={"detail-hero-#{@movie.id}"}
        image={Detail.hero_image(@movie, @movie.stream_icon)}
        alt={@movie.name}
        back_path={back_path(@mode, @provider)}
        fallback_hook?
      />
      
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
              <.detail_title
                title={@movie.title || @movie.name}
                subtitle={alternate_title(@movie)}
                tagline={@movie.tagline}
              />

              <div :if={@mode == :browse and not @premium_access} data-premium-badge>
                <.premium_badge />
              </div>
              
    <!-- Meta Tags -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-1.5 sm:gap-2">
                <.content_rating_badge rating={@movie.content_rating} />
                <.rating_badge rating={@movie.rating} />
                <.year_badge year={@movie.year} />
                <.duration_badge seconds={@movie.duration_secs} />
                <.extension_badge extension={@movie.container_extension} />
              </div>
              
    <!-- Genres -->
              <.genre_chips genres={@movie.genres} />
              
    <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button event="play_movie" label="Assistir Agora" />

                <StreamixWeb.WatchPartyComponents.create_party_button
                  content_type="movie"
                  content_id={@movie.id}
                />

                <.favorite_button favorite?={@is_favorite} />
                <.trailer_link youtube_id={@movie.youtube_trailer} />
                <.tmdb_link type="movie" tmdb_id={@movie.tmdb_id} />
              </div>

              <.premium_cta_banner
                :if={@mode == :browse and not @premium_access}
                id="movie-detail-premium-cta"
                current_scope={@current_scope}
              />
              
    <!-- Synopsis -->
              <.synopsis_section text={@movie.plot} />
              
    <!-- Details Grid -->
              <.credits_grid content={@movie} />
            </div>
          </div>
          
    <!-- Image Gallery -->
          <.image_gallery
            images={if Movie.has_images?(@movie), do: Movie.image_urls(@movie), else: []}
            alt="Imagem do filme"
          />
          
    <!-- Similar Movies -->
          <.similar_grid
            items={@similar_movies}
            kind={:movie}
            mode={@mode}
            provider={@provider}
            title="Títulos Similares"
          />
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

  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    if title != name, do: name
  end

  defp alternate_title(_), do: nil
end
