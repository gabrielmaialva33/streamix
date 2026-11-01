defmodule StreamixWeb.Content.MovieDetailLive do
  @moduledoc """
  LiveView for displaying movie details before playback.
  Works for both /browse/movies/:id (global provider) and /providers/:id/movies/:id (user provider).
  """
  use StreamixWeb, :live_view
  alias StreamixWeb.Content.Detail
  alias StreamixWeb.Content.DisplayTitle
  alias StreamixWeb.Content.SourceBadges
  alias StreamixWeb.LiveSessionNavigation
  alias StreamixWeb.PlayerHelpers

  import StreamixWeb.SourcePickerComponents
  import StreamixWeb.App.Premium
  import StreamixWeb.CoreComponents, only: [icon: 1]
  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  import StreamixWeb.Content.DetailComponents.Actions,
    only: [favorite_button: 1, play_button: 1, tmdb_link: 1, trailer_link: 1]

  import StreamixWeb.Content.DetailComponents.Badges,
    only: [
      content_rating_badge: 1,
      duration_badge: 1,
      extension_badge: 1,
      rating_badge: 1,
      year_badge: 1
    ]

  import StreamixWeb.Content.DetailComponents,
    only: [
      credits_grid: 1,
      detail_hero: 1,
      detail_title: 1,
      gallery_preview: 1,
      genre_chips: 1,
      image_gallery: 1,
      similar_grid: 1,
      synopsis_section: 1
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
        target = back_path(return_to, mode, provider)

        {:ok,
         socket
         |> put_flash(:error, "Filme não encontrado")
         |> LiveSessionNavigation.navigate("/browse/movies", target)}

      movie ->
        is_favorite =
          Detail.favorite?(socket.assigns.current_scope.library_key, "movie", movie.id)

        # Prewarm the upstream redirect chain in the background. The
        # user is on the detail page now and will likely click play in
        # a few seconds — by then the resolution is cached.
        maybe_prewarm_upstream_redirect(socket, provider, movie, user_id)

        current_path =
          mode
          |> detail_base_path(provider, movie)
          |> with_provider_filter(provider_filter)
          |> with_return_to(return_to)

        preferred_provider_id = preferred_provider_id(provider_filter, mode, provider)

        movie_variants =
          movie
          |> Detail.movie_variants(user_id)
          |> ensure_current_variant(movie)
          |> sort_movie_variants(movie.id, preferred_provider_id)
          |> SourceBadges.distinct_copies(movie.id)

        selected_movie = selected_variant(movie_variants, movie, preferred_provider_id)
        movie_watch_paths = build_watch_paths(movie_variants, current_path)

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
          |> assign(similar_movies: [])
          |> assign(movie_variants: movie_variants)
          |> assign(selected_movie: selected_movie)
          |> assign(movie_watch_paths: movie_watch_paths)
          |> assign(selected_watch_path: Map.fetch!(movie_watch_paths, selected_movie.id))
          |> assign(source_options: source_options(movie_variants, user))
          |> assign(selected_gallery_image: nil)
          |> start_detail_tasks(movie)

        {:ok, socket}
    end
  end

  def handle_async({:movie_enrichment, movie_id}, {:ok, movie}, socket)
      when movie_id == socket.assigns.movie.id do
    {:noreply,
     socket
     |> assign(page_title: movie.title || movie.name)
     |> assign(page_description: movie.plot || "Assista #{movie.title || movie.name} no Streamix")
     |> assign(og_image: og_image_url(movie))
     |> assign(movie: movie)
     |> assign(lcp_image: Detail.hero_image(movie, movie.stream_icon))}
  end

  def handle_async({:movie_recommendations, movie_id}, {:ok, movies}, socket)
      when movie_id == socket.assigns.movie.id do
    {:noreply, assign(socket, similar_movies: movies)}
  end

  def handle_async({task, _movie_id}, {:ok, _result}, socket)
      when task in [:movie_enrichment, :movie_recommendations],
      do: {:noreply, socket}

  def handle_async({task, _movie_id}, {:exit, _reason}, socket)
      when task in [:movie_enrichment, :movie_recommendations],
      do: {:noreply, socket}

  # ============================================
  # Event Handlers
  # ============================================

  # ?source=<movie_id> picks one of the authorized copies; anything else keeps
  # the recommended one.
  def handle_params(params, _uri, %{assigns: %{movie_variants: variants}} = socket) do
    variant =
      case Integer.parse(to_string(params["source"])) do
        {id, ""} -> Enum.find(variants, &(&1.id == id))
        _ -> nil
      end

    {:noreply, if(variant, do: select_variant(socket, variant), else: socket)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("select_source", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: with_source(socket.assigns.current_path, id))}
  end

  def handle_event("play_movie", _, socket) do
    {:noreply, redirect(socket, to: socket.assigns.selected_watch_path)}
  end

  def handle_event("toggle_favorite", _, socket) do
    library_key = socket.assigns.current_scope.library_key
    movie = socket.assigns.movie
    is_favorite = socket.assigns.is_favorite

    {:noreply,
     assign(socket, is_favorite: Detail.toggle_movie_favorite(library_key, movie, is_favorite))}
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
                title={DisplayTitle.title(@movie)}
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

              <div id="movie-sources" class="space-y-2 pt-2 text-left">
                <h2
                  :if={length(@source_options) > 1}
                  class="text-xs font-semibold uppercase tracking-wide text-text-secondary"
                >
                  Fonte
                </h2>
                <.source_picker
                  id="movie-source-picker"
                  options={@source_options}
                  selected={@selected_movie.id}
                  event="select_source"
                />
              </div>

              <!-- Action Buttons -->
              <div class="flex flex-wrap items-center justify-center lg:justify-start gap-2 sm:gap-3 pt-2">
                <.play_button event="play_movie" label="Assistir" />

                <div class="title-secondary-actions">
                  <StreamixWeb.WatchPartyComponents.create_party_button
                    content_type="movie"
                    content_id={@selected_movie.id}
                  />

                  <.favorite_button favorite?={@is_favorite} />
                  <.trailer_link youtube_id={@movie.youtube_trailer} />
                  <.tmdb_link type="movie" tmdb_id={@movie.tmdb_id} />
                </div>
              </div>

              <.premium_cta_banner
                :if={@mode == :browse and not @premium_access}
                id="movie-detail-premium-cta"
                current_scope={@current_scope}
              />

              <%!-- Synopsis --%>
              <.synopsis_section text={@movie.plot} />

              <!-- Details Grid -->
              <.credits_grid content={@movie} />
            </div>
          </div>

          <!-- Image Gallery -->
          <.image_gallery
            images={
              if Streamix.Catalog.has_images?(@movie),
                do: Streamix.Catalog.image_urls(@movie),
                else: []
            }
            alt="Imagem do filme"
          />

          <!-- Similar Movies -->
          <.similar_grid
            items={@similar_movies}
            kind={:movie}
            mode={@mode}
            provider={@provider}
            return_to={@current_path}
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

  defp og_image_url(movie) do
    case Streamix.Catalog.backdrop_urls(movie) do
      [url | _] -> url
      _ -> og_image_url_fallback(movie)
    end
  end

  defp og_image_url_fallback(%{stream_icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp og_image_url_fallback(_), do: nil

  defp back_path(return_to, _mode, _provider) when is_binary(return_to), do: return_to
  defp back_path(_return_to, :browse, _provider), do: ~p"/browse/movies"
  defp back_path(_return_to, :provider, provider), do: ~p"/providers/#{provider.id}/movies"

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
    Streamix.Playback.sort_stream_sources(variants,
      media_type: :movie,
      current_source_id: current_movie_id,
      preferred_provider_id: preferred_provider_id
    )
  end

  defp selected_variant([variant | _], _movie, _preferred_provider_id), do: variant
  defp selected_variant([], movie, _preferred_provider_id), do: movie

  defp watch_path(%{provider_type: :torrent}, movie, return_to) do
    case Detail.best_torrent_stream(movie.id) do
      %{id: stream_id} -> with_return_to(~p"/watch/torrent/#{stream_id}", return_to)
      _ -> with_return_to(~p"/watch/movie/#{movie.id}", return_to)
    end
  end

  defp watch_path(_provider, movie, return_to),
    do: with_return_to(~p"/watch/movie/#{movie.id}", return_to)

  defp build_watch_paths(variants, return_to) do
    Map.new(variants, fn variant ->
      {variant.id, watch_path(variant.provider, variant, return_to)}
    end)
  end

  defp maybe_prewarm_upstream_redirect(_socket, %{provider_type: :torrent}, _movie, _user_id),
    do: :ok

  defp maybe_prewarm_upstream_redirect(socket, _provider, movie, user_id) do
    if connected?(socket), do: PlayerHelpers.prewarm_upstream_redirect("movie", movie, user_id)
  end

  defp start_detail_tasks(socket, movie) do
    if connected?(socket) do
      socket
      |> start_async({:movie_enrichment, movie.id}, fn ->
        Detail.maybe_fetch_movie_info(movie)
      end)
      |> start_async({:movie_recommendations, movie.id}, fn ->
        Detail.similar_movies(movie)
      end)
    else
      socket
    end
  end

  # The original name, only when it says more than the displayed title does
  # (not "Dawson's Creek (1998)" under "Dawson's Creek").
  defp alternate_title(%{title: title, name: name}) when is_binary(title) and is_binary(name) do
    shown = DisplayTitle.clean(title)
    original = DisplayTitle.clean(name)
    if String.downcase(shown) != String.downcase(original), do: original
  end

  defp alternate_title(_), do: nil

  defp select_variant(socket, variant) do
    socket
    |> assign(selected_movie: variant)
    |> assign(selected_watch_path: Map.fetch!(socket.assigns.movie_watch_paths, variant.id))
  end

  defp with_source(path, id) do
    uri = URI.parse(path)
    query = (uri.query || "") |> URI.decode_query() |> Map.put("source", to_string(id))
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  # Same presentation as the series and episode pages: only what tells the
  # copies apart.
  defp source_options(variants, user) do
    statuses = Streamix.Providers.provider_health_statuses(Enum.map(variants, & &1.provider))

    variants
    |> Enum.with_index()
    |> Enum.map(fn {variant, index} ->
      %{
        id: variant.id,
        label: provider_name(variant),
        badges: SourceBadges.badges(variant),
        note: nil,
        recommended: index == 0,
        unstable: Map.get(statuses, variant.provider_id) == :degraded,
        locked: not Detail.premium_access?(user, variant.provider)
      }
    end)
  end

  defp provider_name(%{provider: %{name: name}}) when is_binary(name) and name != "", do: name
  defp provider_name(%{provider_id: provider_id}), do: "Provedor #{provider_id}"
end
