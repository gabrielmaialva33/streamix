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
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

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
    return_to = safe_return_path(params["return_to"])
    provider_filter = provider_query_param(params["provider"])

    Detail.with_provider(socket, :provider, params, fn provider ->
      mount_with_provider(
        socket,
        provider,
        movie_id,
        user_id,
        :provider,
        return_to,
        provider_filter
      )
    end)
  end

  # Mount for /browse/movies/:id (global provider)
  def mount(%{"id" => movie_id} = params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    return_to = safe_return_path(params["return_to"])
    provider_filter = provider_query_param(params["provider"])

    Detail.with_provider(socket, :browse, %{}, fn provider ->
      mount_with_provider(
        socket,
        provider,
        movie_id,
        user_id,
        :browse,
        return_to,
        provider_filter
      )
    end)
  end

  defp mount_with_provider(socket, provider, movie_id, user_id, mode, return_to, provider_filter) do
    user = socket.assigns.current_scope.user

    movie =
      case parse_positive_integer(movie_id) do
        {:ok, movie_id} -> Detail.get_playable_movie(user_id, movie_id)
        :error -> nil
      end

    case movie do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> push_navigate(to: back_path(return_to, mode, provider))}

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
          mode
          |> detail_base_path(provider, movie)
          |> with_provider_filter(provider_filter)

        preferred_provider_id = preferred_provider_id(provider_filter, mode, provider)

        movie_variants =
          movie
          |> Detail.movie_variants(user_id)
          |> ensure_current_variant(movie)
          |> sort_movie_variants(movie.id, preferred_provider_id)

        selected_movie = selected_variant(movie_variants, movie, preferred_provider_id)

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
          |> assign(return_to: return_to)
          |> assign(provider_filter: provider_filter)
          |> assign(preferred_provider_id: preferred_provider_id)
          |> assign(is_favorite: is_favorite)
          |> assign(user_id: user_id)
          |> assign(similar_movies: Detail.similar_movies(movie.id))
          |> assign(movie_variants: movie_variants)
          |> assign(selected_movie: selected_movie)
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
    {:noreply,
     redirect(
       socket,
       to:
         watch_path(
           socket.assigns.provider,
           socket.assigns.selected_movie,
           socket.assigns.current_path
         )
     )}
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
        back_path={back_path(@return_to, @mode, @provider)}
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

              <%!-- Synopsis --%>
              <.synopsis_section text={@movie.plot} />

              <.movie_versions
                variants={@movie_variants}
                current_movie_id={@movie.id}
                selected_movie_id={@selected_movie.id}
                current_path={@current_path}
              />
              
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

  defp back_path(return_to, _mode, _provider) when is_binary(return_to), do: return_to
  defp back_path(_return_to, :browse, _provider), do: ~p"/browse/movies"
  defp back_path(_return_to, :provider, provider), do: ~p"/providers/#{provider.id}/movies"

  defp provider_movies_path(%{provider_id: provider_id}), do: ~p"/providers/#{provider_id}/movies"

  defp provider_category_path(%{provider_id: provider_id}, %{id: category_id}),
    do: ~p"/providers/#{provider_id}/movies?category=#{category_id}"

  defp detail_base_path(:browse, _provider, movie), do: ~p"/browse/movies/#{movie.id}"

  defp detail_base_path(:provider, provider, movie),
    do: ~p"/providers/#{provider.id}/movies/#{movie.id}"

  defp with_return_to(path, return_to) when is_binary(return_to) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "return_to=" <> URI.encode_www_form(return_to)
  end

  defp with_return_to(path, _return_to), do: path

  defp with_provider_filter(path, nil), do: path
  defp with_provider_filter(path, provider_filter), do: path <> "?provider=" <> provider_filter

  defp safe_return_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    end
  end

  defp safe_return_path(_), do: nil

  defp provider_query_param(value) when value in ["all", "global"], do: value

  defp provider_query_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> Integer.to_string(id)
      _ -> nil
    end
  end

  defp provider_query_param(_), do: nil

  defp preferred_provider_id(provider_filter, _mode, _provider) when is_binary(provider_filter) do
    case Integer.parse(provider_filter) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp preferred_provider_id(_provider_filter, :provider, %{id: id}), do: id
  defp preferred_provider_id(_provider_filter, _mode, _provider), do: nil

  defp ensure_current_variant(variants, movie) do
    if Enum.any?(variants, &(&1.id == movie.id)), do: variants, else: [movie | variants]
  end

  defp sort_movie_variants(variants, current_movie_id, preferred_provider_id) do
    Enum.sort_by(variants, fn variant ->
      {
        provider_rank(variant.provider_id, preferred_provider_id),
        current_rank(variant.id, current_movie_id),
        -quality_score(variant),
        provider_name(variant),
        variant.title || variant.name || ""
      }
    end)
  end

  defp selected_variant([variant | _], _movie, _preferred_provider_id), do: variant
  defp selected_variant([], movie, _preferred_provider_id), do: movie

  defp provider_rank(provider_id, provider_id) when not is_nil(provider_id), do: 0
  defp provider_rank(_provider_id, _preferred_provider_id), do: 1

  defp current_rank(current_movie_id, current_movie_id), do: 0
  defp current_rank(_variant_id, _current_movie_id), do: 1

  defp movie_versions(assigns) do
    ~H"""
    <section :if={length(@variants) > 0} class="space-y-3 pt-2 pb-16 md:pb-2 text-left">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-base sm:text-lg font-semibold text-text-primary">
          {if length(@variants) == 1, do: "Fonte disponível", else: "Versões disponíveis"}
        </h2>
        <span class="text-xs text-text-muted">
          {length(@variants)} {if length(@variants) == 1, do: "fonte", else: "fontes"}
        </span>
      </div>

      <div class="grid gap-2">
        <article
          :for={variant <- @variants}
          class={[
            "rounded-lg border bg-surface/80 p-3 sm:p-4 transition-colors",
            variant.id == @selected_movie_id && "border-brand/60 ring-1 ring-brand/30",
            variant.id != @selected_movie_id && "border-border hover:border-brand/40"
          ]}
        >
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <span class="truncate text-sm font-semibold text-text-primary">
                  {variant.title || variant.name}
                </span>
                <span
                  :if={variant.id == @selected_movie_id}
                  class="rounded bg-brand/15 px-1.5 py-0.5 text-[10px] font-bold uppercase text-brand"
                >
                  Selecionada
                </span>
                <span
                  :if={variant.id == @current_movie_id and variant.id != @selected_movie_id}
                  class="rounded bg-brand/15 px-1.5 py-0.5 text-[10px] font-bold uppercase text-brand"
                >
                  Atual
                </span>
              </div>

              <div class="flex flex-wrap items-center gap-1.5 text-xs text-text-secondary">
                <span class="inline-flex items-center gap-1 rounded bg-surface-hover px-2 py-1">
                  <.icon name="hero-server-stack" class="size-3.5" />
                  {provider_name(variant)}
                </span>
                <span class="rounded bg-surface-hover px-2 py-1">
                  Stream {variant.stream_id}
                </span>
                <span
                  :for={badge <- version_badges(variant)}
                  class="rounded bg-brand/10 px-2 py-1 font-medium text-brand"
                >
                  {badge}
                </span>
              </div>

              <div class="flex flex-wrap gap-1.5">
                <.link
                  :for={category <- version_categories(variant)}
                  navigate={provider_category_path(variant, category)}
                  class="inline-flex min-h-9 items-center rounded bg-white/5 px-2 py-1 text-[11px] text-text-muted hover:bg-brand/10 hover:text-text-primary"
                >
                  {category.name}
                </.link>
              </div>
            </div>

            <div class="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:shrink-0">
              <.link
                href={with_return_to(~p"/watch/movie/#{variant.id}", @current_path)}
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md bg-brand px-3 py-2 text-xs font-semibold text-white hover:bg-brand-hover sm:flex-none"
              >
                <.icon name="hero-play-solid" class="size-3.5" /> Assistir
              </.link>
              <.link
                navigate={provider_movies_path(variant)}
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md border border-border bg-surface-hover px-3 py-2 text-xs font-semibold text-text-primary hover:border-brand/60 sm:flex-none"
              >
                <.icon name="hero-funnel" class="size-3.5" /> Catálogo
              </.link>
              <.link
                :if={variant.id != @current_movie_id}
                navigate={
                  ~p"/providers/#{variant.provider_id}/movies/#{variant.id}?return_to=#{@current_path}"
                }
                class="inline-flex min-h-11 flex-1 items-center justify-center gap-1.5 rounded-md border border-border px-3 py-2 text-xs font-semibold text-text-secondary hover:border-brand/60 hover:text-text-primary sm:flex-none"
              >
                <.icon name="hero-information-circle" class="size-3.5" /> Detalhes
              </.link>
            </div>
          </div>
        </article>
      </div>
    </section>
    """
  end

  # Torrent movies play through the rqbit swarm gate (/watch/torrent/:id,
  # where :id is the best torrent_stream). Everything else is a direct
  # VOD play keyed on the movie id.
  defp watch_path(%{provider_type: :torrent}, movie, return_to) do
    case Detail.best_torrent_stream(movie.id) do
      %{id: stream_id} -> with_return_to(~p"/watch/torrent/#{stream_id}", return_to)
      _ -> with_return_to(~p"/watch/movie/#{movie.id}", return_to)
    end
  end

  defp watch_path(_provider, movie, return_to),
    do: with_return_to(~p"/watch/movie/#{movie.id}", return_to)

  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    if title != name, do: name
  end

  defp alternate_title(_), do: nil

  defp provider_name(%{provider: %{name: name}}) when is_binary(name) and name != "", do: name
  defp provider_name(%{provider_id: provider_id}), do: "Provider #{provider_id}"

  defp version_categories(%{categories: categories}) when is_list(categories) do
    categories
    |> Enum.reject(& &1.is_adult)
    |> Enum.take(4)
  end

  defp version_categories(_), do: []

  defp version_badges(variant) do
    source = "#{variant.name} #{variant.title}"
    downcased = String.downcase(source)

    [
      extension_label(variant.container_extension),
      contains_badge(downcased, "4k", "4K"),
      contains_badge(downcased, "hdr", "HDR"),
      contains_badge(downcased, "legendado", "LEG"),
      contains_badge(downcased, "dublado", "DUB")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extension_label(extension) when is_binary(extension) and extension != "",
    do: String.upcase(extension)

  defp extension_label(_), do: nil

  defp contains_badge(value, needle, label) do
    if String.contains?(value, needle), do: label
  end

  defp quality_score(variant) do
    source = String.downcase("#{variant.name} #{variant.title}")

    [
      {String.contains?(source, "4k"), 40},
      {String.contains?(source, "2160p"), 35},
      {String.contains?(source, "hdr"), 20},
      {String.contains?(source, "1080p"), 10}
    ]
    |> Enum.reduce(0, fn
      {true, points}, score -> score + points
      {false, _points}, score -> score
    end)
  end
end
